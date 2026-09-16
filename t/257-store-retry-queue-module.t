use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use DBI;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-257: D2TG::Store.pm had grown to 1528 lines. Its retry-queue subs
# (failed_downloads/failed_transcriptions, ~200 lines across 10 subs) are
# the largest cleanly-separable concern - this proves the extracted
# D2TG::Store::RetryQueue module works standalone against a bare DBI
# handle, independent of D2TG::Store itself.
require D2TG::Store::RetryQueue;

my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
my $dbh = DBI->connect( "dbi:SQLite:dbname=$db_path", '', '', { RaiseError => 1, AutoCommit => 1 } );

$dbh->do(<<'SQL');
CREATE TABLE failed_downloads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    bot_key TEXT NOT NULL DEFAULT '',
    message_id INTEGER NOT NULL,
    file_id TEXT,
    sender TEXT,
    media_kind TEXT,
    caption_note TEXT,
    error TEXT,
    local_path TEXT,
    last_retry_at TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(chat_id, bot_key, message_id)
)
SQL

$dbh->do(<<'SQL');
CREATE TABLE failed_transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    bot_key TEXT NOT NULL DEFAULT '',
    message_id INTEGER NOT NULL,
    file_id TEXT,
    sender TEXT,
    error TEXT,
    last_retry_at TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(chat_id, bot_key, message_id)
)
SQL

my $rq = D2TG::Store::RetryQueue->new( dbh => $dbh );
isa_ok( $rq, 'D2TG::Store::RetryQueue' );

# --- failed_downloads ---
my $id1 = $rq->record_failed_download( 111, 1, 'file-a', sender => 'alice', media_kind => 'photo', error => 'boom' );
ok( $id1, 'record_failed_download returns an id' );

my $rows = $rq->failed_downloads;
is( scalar(@$rows), 1, 'failed_downloads lists the one queued row' );
is( $rows->[0]{chat_id}, 111, 'row carries the right chat_id' );

# redelivery refresh: same (chat_id, bot_key, message_id) updates, not duplicates
my $id1b = $rq->record_failed_download( 111, 1, 'file-a-refreshed', sender => 'alice', error => 'boom again' );
is( $id1b, $id1, 'redelivery of the same message_id refreshes the same row' );
is( scalar( @{ $rq->failed_downloads } ), 1, 'still only one row after refresh' );

# multi-bot isolation
my $id2 = $rq->record_failed_download( 111, 1, 'file-b', bot_key => 'botB', sender => 'alice', error => 'boom' );
isnt( $id2, $id1, 'same chat_id/message_id under a different bot_key queues a separate row' );
is( scalar( @{ $rq->failed_downloads( bot_key => 'botB' ) } ), 1, 'bot_key filter isolates the second bot\'s row' );

my $due = $rq->failed_downloads_due_for_retry;
is( scalar(@$due), 2, 'both freshly-queued rows are due for retry' );

$rq->mark_failed_download_retried($id1);
my $due_after_mark = $rq->failed_downloads_due_for_retry;
is( scalar(@$due_after_mark), 1, 'the just-retried row drops out of the due-for-retry window' );

$rq->mark_failed_download_downloaded( $id1, '/tmp/some/local/path' );
my ($row) = grep { $_->{id} == $id1 } @{ $rq->failed_downloads };
is( $row->{local_path}, '/tmp/some/local/path', 'mark_failed_download_downloaded persists the local path' );

$rq->remove_failed_download($id1);
is( scalar( @{ $rq->failed_downloads } ), 1, 'remove_failed_download deletes the row' );

# --- failed_transcriptions (mirrors failed_downloads exactly) ---
my $tid1 = $rq->record_failed_transcription( 222, 5, 'file-t', sender => 'bob', error => 'whisper timeout' );
ok( $tid1, 'record_failed_transcription returns an id' );
is( scalar( @{ $rq->failed_transcriptions } ), 1, 'failed_transcriptions lists the one queued row' );

my $tdue = $rq->failed_transcriptions_due_for_retry;
is( scalar(@$tdue), 1, 'transcription row is due for retry' );

$rq->mark_failed_transcription_retried($tid1);
is( scalar( @{ $rq->failed_transcriptions_due_for_retry } ), 0, 'the just-retried transcription drops out of the due window' );

$rq->remove_failed_transcription($tid1);
is( scalar( @{ $rq->failed_transcriptions } ), 0, 'remove_failed_transcription deletes the row' );

done_testing();
