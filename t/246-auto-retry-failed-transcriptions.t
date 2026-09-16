use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;
require D2TG::Download;
require D2TG::Transcribe;
require D2TG::Transcribe::Retry;

# TGT-246 (found via a scheduled JOB-003 hourly bug hunt): TGT-221 gave
# failed_downloads automatic background retry (every 60s for up to 5
# minutes, Q-015), but the structurally identical failed_transcriptions
# queue (TGT-237) never got the same treatment - only a manual
# d2 tg.retry-transcription existed. D2TG::Transcribe::Retry::auto_retry_failed_transcriptions
# closes that gap, reusing retry_failed_transcription exactly like
# auto_retry_failed_downloads reuses retry_failed_download. This test
# file mirrors t/221-auto-retry-failed-downloads.t's own shape, applied
# to the transcription queue.

package main;

# D2TG::Store: last_retry_at tracking + the due-for-retry query, mirroring
# failed_downloads_due_for_retry/mark_failed_download_retried exactly.
{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    my $id = $store->record_failed_transcription(
        1, 1, 'voice-a', sender => 'ada', error => 'e',
    );

    my @due = @{ $store->failed_transcriptions_due_for_retry };
    is( scalar @due, 1, 'a freshly-queued row (never auto-retried) is immediately due for retry' );
    is( $due[0]{id}, $id, 'the due row is the one just queued' );

    $store->mark_failed_transcription_retried($id);
    @due = @{ $store->failed_transcriptions_due_for_retry };
    is( scalar @due, 0, 'a row just retried is not due again immediately (within the 60s interval)' );

    $store->{dbh}->do(
        q{UPDATE failed_transcriptions SET last_retry_at = datetime('now', '-61 seconds') WHERE id = ?}, undef, $id,
    );
    @due = @{ $store->failed_transcriptions_due_for_retry };
    is( scalar @due, 1, 'a row last retried over 60s ago is due again' );

    $store->{dbh}->do(
        q{UPDATE failed_transcriptions SET created_at = datetime('now', '-301 seconds') WHERE id = ?}, undef, $id,
    );
    @due = @{ $store->failed_transcriptions_due_for_retry };
    is( scalar @due, 0, 'a row queued over 5 minutes ago is no longer due for auto-retry (outside the window)' );

    my $list = $store->failed_transcriptions;
    is( scalar @$list, 1, 'the row is still queued and visible even though auto-retry has given up on it' );
}

# D2TG::Transcribe::Retry::auto_retry_failed_transcriptions: a successful retry
# removes the row, exactly like a manual retry_failed_transcription would.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    $store->record_failed_transcription(
        999, 55, 'AABBqueued', sender => 'ada', error => 'e',
    );

    no warnings 'once';
    local *D2TG::Download::download_file = sub { return '/tmp/does-not-matter-tgt246-a.oga' };
    local *D2TG::Transcribe::transcribe  = sub { return 'recovered transcript' };

    D2TG::Transcribe::Retry::auto_retry_failed_transcriptions( 'fake-telegram', $store );

    is_deeply( $store->failed_transcriptions, [], 'a successfully auto-retried row is removed from the queue' );
    my $restored = $store->get_message( 999, 55 );
    ok( $restored, 'the message is restored into history on a successful auto-retry' );
    is( $restored->{summary}, 'recovered transcript', 'restored message summary is the transcript itself' );
}

# A failed auto-retry attempt updates last_retry_at and leaves the row
# queued - never crashes the caller.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_transcription(
        999, 56, 'AABBfails', sender => 'ada', error => 'e',
    );

    no warnings 'once';
    local *D2TG::Download::download_file = sub { die "still unreachable\n" };

    my $ok = eval { D2TG::Transcribe::Retry::auto_retry_failed_transcriptions( 'fake-telegram', $store ); 1 };
    ok( $ok, 'auto_retry_failed_transcriptions never dies, even when the underlying retry fails' );

    my ($row) = @{ $store->failed_transcriptions };
    ok( $row, 'the row is still queued after a failed auto-retry attempt' );
    ok( $row->{last_retry_at}, 'last_retry_at is updated after the failed attempt' );

    my @due = @{ $store->failed_transcriptions_due_for_retry };
    is( scalar @due, 0, 'immediately after a failed attempt, the row is not due again until the 60s interval elapses' );
}

# bot_key scoping: only the given bot's own queue is auto-retried.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    $store->record_failed_transcription( 1, 1, 'voice-a', sender => 'ada', error => 'e', bot_key => 'tokenA' );
    $store->record_failed_transcription( 1, 2, 'voice-b', sender => 'ada', error => 'e', bot_key => 'tokenB' );

    my @due = @{ $store->failed_transcriptions_due_for_retry( bot_key => 'tokenA' ) };
    is( scalar @due, 1, 'bot_key filter scopes the due-for-retry listing to just that bot' );
    is( $due[0]{bot_key}, 'tokenA', 'the filtered row belongs to the requested bot' );
}

done_testing();
