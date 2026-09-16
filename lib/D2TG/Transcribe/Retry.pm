package D2TG::Transcribe::Retry;

use strict;
use warnings;
use D2TG::Poller;
use D2TG::Download;
use D2TG::Transcribe;

# TGT-263: retry_failed_transcription/auto_retry_failed_transcriptions
# (moved into D2TG::Transcribe by TGT-261) were their own distinct
# concern from the core probe/transcribe/timeout logic - they talk to
# D2TG::Poller::store_write_safe and D2TG::Download::download_file, not
# whisper itself. Extracted here, mirroring D2TG::Store::RetryQueue's
# own precedent (TGT-257). Full documentation lives in
# D2TG/Transcribe/Retry.pod (REQ-028: POD in a separate file).
sub retry_failed_transcription {
    my ( $telegram, $store, $row, %args ) = @_;

    my $local_path = eval { D2TG::Download::download_file( $telegram, $row->{file_id}, ua => $args{ua} ) };
    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        return ( 0, $error );
    }

    my $transcript = eval { D2TG::Transcribe::transcribe($local_path) };
    my $transcribe_error = $@;
    unlink $local_path;

    if ($transcribe_error) {
        my $error = $transcribe_error;
        $error =~ s/\n\z//;
        return ( 0, $error );
    }

    my ($record_ok) = D2TG::Poller::store_write_safe(
        $row->{chat_id}, 'record_message',
        sub {
            $store->record_message(
                $row->{chat_id}, $row->{message_id}, $row->{sender}, $transcript,
                bot_key => $row->{bot_key},
            );
        }
    );

    my $remove_ok;
    if ($record_ok) {
        ($remove_ok) =
          D2TG::Poller::store_write_safe( $row->{chat_id}, 'remove_failed_transcription', sub { $store->remove_failed_transcription( $row->{id} ) } );
    }
    else {
        print STDERR "STORE ERROR [$row->{chat_id}]: queue row not removed - "
          . "a future retry can still restore history for this message, without re-transcribing\n";
    }

    return ( 1, $transcript, ( $record_ok && $remove_ok ) ? 0 : 1 );
}

sub auto_retry_failed_transcriptions {
    my ( $telegram, $store, %args ) = @_;

    my $due = $store->failed_transcriptions_due_for_retry(
        defined $args{bot_key} ? ( bot_key => $args{bot_key} ) : ()
    );

    for my $row (@$due) {
        retry_failed_transcription( $telegram, $store, $row, ua => $args{ua} );

        my $still_queued = grep { $_->{id} == $row->{id} } @{ $store->failed_transcriptions };
        if ($still_queued) {
            eval { $store->mark_failed_transcription_retried( $row->{id} ) };
        }
    }

    return;
}

1;
