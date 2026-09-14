use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

# TGT-238 (found via a scheduled JOB-004 improvement hunt):
# D2TG::Store::prune_history (TGT-235) added retention for messages/
# sent_replies but deliberately left failed_downloads/
# failed_transcriptions out of scope - those two tables had (and,
# pre-fix, still have) no retention policy at all: a row is removed
# only by a successful retry, so a permanently-unretryable row (an
# expired Telegram file_id, say) sits in the queue forever. prune_history
# now also sweeps both retry queues, using a separate (shorter) default
# window from the messages/sent_replies one.

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    my $old_id = $store->record_failed_download(
        1, 1, 'old-file', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e1',
    );
    my $fresh_id = $store->record_failed_download(
        1, 2, 'fresh-file', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e2',
    );
    $store->{dbh}->do(
        q{UPDATE failed_downloads SET created_at = datetime('now', '-200 days') WHERE id = ?}, undef, $old_id,
    );

    $store->prune_history;

    my @remaining_ids = map { $_->{id} } @{ $store->failed_downloads };
    ok( !( grep { $_ == $old_id } @remaining_ids ), 'an aged-out failed_downloads row is evicted by prune_history' );
    ok( ( grep { $_ == $fresh_id } @remaining_ids ), 'a fresh failed_downloads row survives prune_history' );
}

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    my $old_id = $store->record_failed_transcription(
        1, 1, 'old-voice', sender => 'ada', error => 'whisper crashed',
    );
    my $fresh_id = $store->record_failed_transcription(
        1, 2, 'fresh-voice', sender => 'ada', error => 'whisper crashed again',
    );
    $store->{dbh}->do(
        q{UPDATE failed_transcriptions SET created_at = datetime('now', '-200 days') WHERE id = ?}, undef, $old_id,
    );

    $store->prune_history;

    my @remaining_ids = map { $_->{id} } @{ $store->failed_transcriptions };
    ok( !( grep { $_ == $old_id } @remaining_ids ), 'an aged-out failed_transcriptions row is evicted by prune_history' );
    ok( ( grep { $_ == $fresh_id } @remaining_ids ), 'a fresh failed_transcriptions row survives prune_history' );
}

{
    # Configurable window: a caller-supplied override applies to the
    # failed-queue sweep too, independent of the messages/sent_replies
    # retention_days argument.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    my $id = $store->record_failed_download(
        1, 1, 'ten-days-old', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e',
    );
    $store->{dbh}->do(
        q{UPDATE failed_downloads SET created_at = datetime('now', '-10 days') WHERE id = ?}, undef, $id,
    );

    $store->prune_history( failed_queue_retention_days => 5 );

    is_deeply( $store->failed_downloads, [], 'a caller-supplied shorter failed_queue_retention_days evicts a row still within the default window' );
}

{
    # No-op when nothing is past the window, for both queues.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    $store->record_failed_download( 1, 1, 'f', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e' );
    $store->record_failed_transcription( 1, 2, 'v', sender => 'ada', error => 'e' );

    $store->prune_history;

    is( scalar @{ $store->failed_downloads }, 1, 'a store fully within the window is left untouched (failed_downloads)' );
    is( scalar @{ $store->failed_transcriptions }, 1, 'a store fully within the window is left untouched (failed_transcriptions)' );
}

done_testing();
