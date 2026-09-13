use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use DBI;

require D2TG::Store;
require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

# TGT-219 (found via a scheduled JOB-004 improvement hunt): every other
# per-chat D2TG::Store table (allow_list/pending/sent_replies) carries a
# bot_key column so a multi-bot config (bot_groups, TGT-098/202/213/218)
# stays correctly scoped - failed_downloads was the sole exception,
# keyed only on (chat_id, message_id). Telegram's own file_id values are
# bot-token-scoped, so a media-download failure recorded under one bot
# and retried as another bot would fail against Telegram entirely.

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    my $store = new_store();

    $store->record_failed_download( 111, 55, 'fileA', bot_key => 'tokenA', error => 'boom' );
    $store->record_failed_download( 111, 55, 'fileB', bot_key => 'tokenB', error => 'boom' );

    my $all = $store->failed_downloads;
    is( scalar @$all, 2,
        'the same (chat_id, message_id) under two different bot_keys queues two separate rows, not one collapsed via ON CONFLICT' );

    my $scoped_a = $store->failed_downloads( bot_key => 'tokenA' );
    is( scalar @$scoped_a, 1, 'failed_downloads(bot_key => tokenA) returns only that bot\'s own queued entry' );
    is( $scoped_a->[0]{file_id}, 'fileA', 'the correct entry is returned' );

    my $scoped_b = $store->failed_downloads( bot_key => 'tokenB' );
    is( scalar @$scoped_b, 1, 'failed_downloads(bot_key => tokenB) returns only that bot\'s own queued entry' );
    is( $scoped_b->[0]{file_id}, 'fileB', 'the correct entry is returned' );
}

# Regression: single-bot mode (no bot_key ever passed) behaves exactly
# as before - one queue row per (chat_id, message_id), unscoped listing
# still works.
{
    my $store = new_store();

    $store->record_failed_download( 222, 77, 'file1', error => 'boom' );
    $store->record_failed_download( 222, 77, 'file2', error => 'boom again' );

    my $all = $store->failed_downloads;
    is( scalar @$all, 1, 'single-bot mode: a redelivered failure for the same (chat_id, message_id) still refreshes one row, not two' );
    is( $all->[0]{file_id}, 'file2', 'single-bot mode: the refreshed row has the latest file_id' );
}

# D2TG::Poller::run_once must actually thread $bot_token through to
# record_failed_download, not just D2TG::Store support the parameter.
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 3000,
                message   => { message_id => 66, chat => { id => 444 }, from => { username => 'ada' }, document => { file_id => 'photo123' } },
            },
        ],
    );
    my $download_media = sub { die "simulated download failure\n" };

    my $store = Fake::Store->new( allowed => [444] );
    D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media, bot_token => 'the-real-bot-token' );

    my ($row) = grep { $_->{chat_id} == 444 && $_->{message_id} == 66 } @{ $store->failed_downloads };
    ok( $row, 'the failed download was queued' );
    is( $row->{bot_key}, 'the-real-bot-token',
        'run_once threads its own $bot_token through to record_failed_download - previously always undef, silently dropped' );
}

# A mid-migration failure must propagate loudly (dies) rather than
# silently leaving a half-migrated/orphaned failed_downloads table -
# matching t/75-multi-bot-allow-list-scoping.t's own established
# precedent for the identical TGT-098 migration shape.
{
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, AutoCommit => 1 } );
    $dbh->do(
        'CREATE TABLE failed_downloads (
             id           INTEGER PRIMARY KEY AUTOINCREMENT,
             chat_id      INTEGER NOT NULL,
             message_id   INTEGER NOT NULL,
             file_id      TEXT NOT NULL,
             sender       TEXT,
             media_kind   TEXT,
             caption_note TEXT,
             error        TEXT,
             created_at   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             local_path   TEXT,
             UNIQUE (chat_id, message_id)
         )'
    );
    $dbh->do('INSERT INTO failed_downloads (chat_id, message_id, file_id) VALUES (999, 1, \'f1\')');
    $dbh->disconnect;

    my $real_do = \&DBI::db::do;
    my $error;
    {
        no warnings 'redefine';
        local *DBI::db::do = sub {
            my ( $self, $sql, @rest ) = @_;
            die "simulated failure mid-migration\n"
              if $sql =~ /INSERT INTO failed_downloads/;
            return $real_do->( $self, $sql, @rest );
        };

        eval { D2TG::Store->new( db_path => $db ) };
        $error = $@;
    }

    like( $error, qr/simulated failure mid-migration/,
        'a failed_downloads mid-migration failure propagates loudly (dies) rather than silently continuing' );

    my $store = D2TG::Store->new( db_path => $db );
    my $rows  = $store->failed_downloads;
    is( scalar @$rows, 1, 'after the simulated failure, a real re-open still migrates successfully and the original row survives' );
}

done_testing();
