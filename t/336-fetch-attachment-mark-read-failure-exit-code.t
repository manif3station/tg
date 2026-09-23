use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use DBI;
use lib "$Bin/lib", "$Bin/../lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

use D2TG::Config;
use D2TG::Store;

# TGT-336 (Q-021 answered by Michael 2026-09-23): cli/fetch.pl and
# cli/attachment.pl both print content FIRST, then call mark_read - a
# mark_read failure used to exit 1, the same code as a genuine "nothing
# was ever shown" failure. Michael chose to give a mark_read-after-
# success failure its own distinct exit code (3), separate from a
# genuine fetch failure (still 1).
#
# cli/fetch.pl and cli/attachment.pl use D2TG::Store directly with no
# dependency-injection hook, so a fake/mock store isn't available for a
# subprocess-level test the way t/193 uses one for D2TG::Poller::run_once.
# A genuine concurrent-lock approach (holding a write transaction open
# from another process) doesn't work here either: D2TG::Store::new
# itself runs ensure_schema's own ALTER TABLE statements on every
# connection (duplicate-tolerant, but still a real write attempt), so
# any external lock held long enough to fail mark_read would also fail
# the store's own opening schema migration first - there's no way to
# selectively block only the later write via a single lock window.
# Instead, a SQLite BEFORE UPDATE trigger on messages.read_at
# deterministically fails only the mark_read UPDATE - SELECTs
# (get_message/get_attachment_path) and the DDL migration (different
# statements entirely) are both completely unaffected.

sub fetch_cli      { return File::Spec->catfile( $Bin, '..', 'cli', 'fetch.pl' ) }
sub attachment_cli { return File::Spec->catfile( $Bin, '..', 'cli', 'attachment.pl' ) }

sub _run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-336-stderr.$$";
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

# Installs a trigger that unconditionally fails any UPDATE of
# messages.read_at (mark_read's own exact statement, verified against
# D2TG::Store::History::mark_read) - SELECTs and DDL are unaffected.
sub _sabotage_mark_read {
    my ($db_path) = @_;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db_path", '', '', { RaiseError => 1, AutoCommit => 1 } );
    $dbh->do(<<'SQL');
CREATE TRIGGER t336_fail_mark_read
BEFORE UPDATE OF read_at ON messages
BEGIN
    SELECT RAISE(ABORT, 'simulated mark_read failure (TGT-336 test)');
END
SQL
    $dbh->disconnect;
    return;
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    $store->record_message( 999, 42, 'ada', 'hello from ada' );
    $store->disconnect;

    _sabotage_mark_read($db_path);

    my ( $out, $rc, $err ) = _run_capturing_stderr( fetch_cli(), 999, 42 );

    is( $out, "hello from ada\n", 'content is still shown even though mark_read will fail' );
    is( $rc, 3, 'd2 tg.fetch exits 3 (not the generic 1) when only the trailing mark_read write fails' );
    like( $err, qr/STORE ERROR: mark_read failed/, 'the refusal names mark_read specifically' );

    my $store2 = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    ok( !$store2->is_read( 999, 42 ), 'the message is NOT marked read, since mark_read genuinely failed' );
    $store2->disconnect;
}

{
    # Sanity: a genuine "nothing ever shown" failure still exits 1, not 3.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my ( $out, $rc, $err ) = _run_capturing_stderr( fetch_cli(), 999, 9999 );

    is( $rc, 1, 'd2 tg.fetch still exits 1 for a genuine "nothing recorded" failure' );
    is( $out, '', 'nothing was ever shown' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $attachments_dir = D2TG::Config::attachments_dir(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    mkdir $attachments_dir unless -d $attachments_dir;
    my $local_path = File::Spec->catfile( $attachments_dir, 't336-attachment.bin' );
    open my $fh, '>', $local_path or die $!;
    print {$fh} 'attachment bytes';
    close $fh;

    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    $store->record_message( 999, 43, 'ada', 'a document', local_path => $local_path );
    $store->disconnect;

    _sabotage_mark_read($db_path);

    my ( $out, $rc, $err ) = _run_capturing_stderr( attachment_cli(), 999, 43 );

    is( $out, 'attachment bytes', 'attachment bytes are still shown even though mark_read will fail' );
    is( $rc, 3, 'd2 tg.attachment exits 3 (not the generic 1) when only the trailing mark_read write fails' );
    like( $err, qr/STORE ERROR: mark_read failed/, 'the refusal names mark_read specifically' );
}

done_testing();
