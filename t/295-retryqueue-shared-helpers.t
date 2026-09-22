use strict;
use warnings;
use Test::More;
use DBI;
use D2TG::Store::RetryQueue;

# TGT-295 (found via a user-requested comprehensive bug/improvement
# sweep): every download-side function in RetryQueue.pm had a
# byte-for-byte transcription-side twin differing only by table name -
# record_failed_download/record_failed_transcription,
# failed_downloads/failed_transcriptions,
# failed_downloads_due_for_retry/failed_transcriptions_due_for_retry,
# mark_failed_download_retried/mark_failed_transcription_retried,
# remove_failed_download/remove_failed_transcription. Collapsed each
# pair onto one table-parameterized private helper - zero observable
# behavior change, confirmed by this test running the exact same
# assertions the pre-refactor behavior already satisfied, plus a
# structural check that the shared helpers actually exist and are used.

my $dbh = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 } );
$dbh->do(
    'CREATE TABLE failed_downloads (
        id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, bot_key TEXT DEFAULT "",
        message_id INTEGER, file_id TEXT, sender TEXT, media_kind TEXT, caption_note TEXT,
        error TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP, local_path TEXT, last_retry_at TEXT,
        UNIQUE(chat_id, bot_key, message_id)
    )'
);
$dbh->do(
    'CREATE TABLE failed_transcriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, bot_key TEXT DEFAULT "",
        message_id INTEGER, file_id TEXT, sender TEXT, error TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP, last_retry_at TEXT, transcript TEXT,
        UNIQUE(chat_id, bot_key, message_id)
    )'
);

my $rq = D2TG::Store::RetryQueue->new( dbh => $dbh );

# Structural: the module now exposes shared private helpers, and each
# public pair is a thin wrapper delegating to one of them.
{
    open my $fh, '<', $INC{'D2TG/Store/RetryQueue.pm'} or die $!;
    local $/;
    my $source = <$fh>;
    close $fh;

    my @helpers = qw(_record_failed _list_failed _due_for_retry _mark_retried _remove_failed);
    for my $helper (@helpers) {
        like( $source, qr/sub \Q$helper\E \{/, "shared private helper $helper is defined" );
    }
    for my $helper (@helpers) {
        my @call_sites = ( $source =~ /\$self->\Q$helper\E\(/g );
        cmp_ok( scalar(@call_sites), '>=', 2, "$helper is called from at least 2 public wrappers (download + transcription)" );
    }
}

# Behavioral: record/list/due-for-retry/mark-retried/remove all still
# work identically for both tables, including bot_key scoping.
my $dl_id = $rq->record_failed_download( 111, 222, 'file-abc', sender => 'alice', media_kind => 'photo', caption_note => 'note', error => 'boom' );
ok( $dl_id, 'record_failed_download returns an id' );

my $downloads = $rq->failed_downloads;
is( scalar(@$downloads), 1, 'failed_downloads lists the queued row' );
is( $downloads->[0]{sender}, 'alice', 'failed_downloads preserves sender' );
is( $downloads->[0]{media_kind}, 'photo', 'failed_downloads preserves media_kind' );

my $due = $rq->failed_downloads_due_for_retry;
is( scalar(@$due), 1, 'failed_downloads_due_for_retry finds the fresh row' );

$rq->mark_failed_download_retried($dl_id);
my $after_mark = $rq->failed_downloads;
ok( defined $after_mark->[0]{last_retry_at}, 'mark_failed_download_retried stamps last_retry_at' );

$rq->remove_failed_download($dl_id);
is( scalar( @{ $rq->failed_downloads } ), 0, 'remove_failed_download removes the row' );

my $tr_id = $rq->record_failed_transcription( 333, 444, 'file-xyz', sender => 'bob', error => 'oops', bot_key => 'botB' );
ok( $tr_id, 'record_failed_transcription returns an id' );

is( scalar( @{ $rq->failed_transcriptions( bot_key => 'botB' ) } ), 1, 'failed_transcriptions scopes by bot_key' );
is( scalar( @{ $rq->failed_transcriptions( bot_key => 'other' ) } ), 0, 'failed_transcriptions bot_key scoping excludes non-matching bot' );

my $tr_due = $rq->failed_transcriptions_due_for_retry( bot_key => 'botB' );
is( scalar(@$tr_due), 1, 'failed_transcriptions_due_for_retry finds the fresh row, scoped by bot_key' );

$rq->mark_failed_transcription_retried($tr_id);
my $tr_after_mark = $rq->failed_transcriptions( bot_key => 'botB' );
ok( defined $tr_after_mark->[0]{last_retry_at}, 'mark_failed_transcription_retried stamps last_retry_at' );

$rq->remove_failed_transcription($tr_id);
is( scalar( @{ $rq->failed_transcriptions( bot_key => 'botB' ) } ), 0, 'remove_failed_transcription removes the row' );

done_testing();
