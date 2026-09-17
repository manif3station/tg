package D2TG::Poller::Dispatch;

use strict;
use warnings;
use D2TG::Poller::Format;
use D2TG::Poller::Safe;

use constant TELEGRAM_GETFILE_MAX_BYTES => 20 * 1024 * 1024;

sub handle_message_reaction {
    my ( $reaction, $store, $bot_token ) = @_;
    my $chat_id = $reaction->{chat}{id};

    if ($store) {
        my ( $ok, $allowed ) =
          D2TG::Poller::Safe::store_write_safe( $chat_id, 'is_allowed', sub { $store->is_allowed( $chat_id, $bot_token ) } );
        return unless $ok;
        return unless $allowed;
    }

    my $message_id = $reaction->{message_id};

    my $sender =
      $reaction->{actor_chat}
      ? D2TG::Poller::Format::sanitize_for_stdout(
        $reaction->{actor_chat}{title} // $reaction->{actor_chat}{username} // 'unknown' )
      : D2TG::Poller::Format::sanitize_for_stdout(
        D2TG::Poller::Format::display_name( $chat_id, $reaction->{user}{username} ) );

    my %old_by_key =
      map { D2TG::Poller::Format::reaction_key($_) => D2TG::Poller::Format::reaction_label($_) }
      @{ $reaction->{old_reaction} // [] };
    my %new_by_key =
      map { D2TG::Poller::Format::reaction_key($_) => D2TG::Poller::Format::reaction_label($_) }
      @{ $reaction->{new_reaction} // [] };

    for my $key ( sort grep { !$old_by_key{$_} } keys %new_by_key ) {
        print "NEW TG REACTION [$chat_id] $sender: "
          . D2TG::Poller::Format::sanitize_for_stdout( $new_by_key{$key} ) . " on message $message_id\n";
    }
    for my $key ( sort grep { !$new_by_key{$_} } keys %old_by_key ) {
        print "REACTION REMOVED [$chat_id] $sender: "
          . D2TG::Poller::Format::sanitize_for_stdout( $old_by_key{$key} ) . " on message $message_id\n";
    }
    return;
}

sub handle_edited_message {
    my ( $edited, $update_id, $offset_cap_ref, $store, $bot_token ) = @_;
    my $chat_id = $edited->{chat}{id};

    if ($store) {
        my ( $ok, $allowed ) =
          D2TG::Poller::Safe::store_write_safe( $chat_id, 'is_allowed', sub { $store->is_allowed( $chat_id, $bot_token ) } );
        return unless $ok;
        return unless $allowed;
    }

    my $sender      = D2TG::Poller::Format::display_name( $chat_id, $edited->{from}{username} );
    my $message_id  = $edited->{message_id};
    my $edited_text = $edited->{text};
    my $has_text    = defined $edited_text && length $edited_text;
    my $safe_text   = $has_text ? D2TG::Poller::Format::sanitize_for_stdout($edited_text) : '(no text)';
    my $ts          = D2TG::Poller::Format::timestamp_prefix($edited);

    if ( $store && $has_text ) {
        my $already_announced = eval { $store->get_message( $chat_id, $message_id, bot_key => $bot_token ) };
        return if !$@ && $already_announced && $already_announced->{summary} eq $safe_text;
    }

    print "$ts NEW TG EDIT [$chat_id] $sender: $safe_text (msg #$message_id, edited)\n";

    D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );

    if ( $store && defined $message_id && $has_text ) {
        D2TG::Poller::Safe::record_message_and_track_offset( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, $safe_text, bot_key => $bot_token );
    }

    return;
}

sub handle_plain_update {
    my ( $update, $update_id, $offset_cap_ref, $telegram, $store, $bot_token, $transcribe_voice, $download_media ) = @_;

    my $message = $update->{message} or return;
    my $text       = $message->{text};
    my $media_kind = D2TG::Poller::Format::media_kind($message);

    return unless ( defined $text && length $text ) || $media_kind;

    my $chat_id = $message->{chat}{id};
    my $sender  = D2TG::Poller::Format::display_name( $chat_id, $message->{from}{username} );

    $sender = D2TG::Poller::Format::format_forwarded_sender( $sender, $message->{forward_origin} );

    my $ts = D2TG::Poller::Format::timestamp_prefix($message);

    if ($store) {
        my ( $ok, $allowed ) =
          D2TG::Poller::Safe::store_write_safe( $chat_id, 'is_allowed', sub { $store->is_allowed( $chat_id, $bot_token ) } );
        return unless $ok;

        unless ($allowed) {
            my ( $add_ok, $added ) =
              D2TG::Poller::Safe::store_write_safe( $chat_id, 'add_pending', sub { $store->add_pending( $chat_id, $bot_token ) } );
            return unless $add_ok;
            if ($added) {
                print "$ts NEW TG PENDING [$chat_id] awaiting approval\n";
            }
            return;
        }
    }

    my $reply_ctx  = D2TG::Poller::Format::reply_context_suffix( $message, $store, $chat_id, $bot_token );
    my $message_id = $message->{message_id};
    my $msg_note   = defined $message_id ? " (msg #$message_id)" : '';

    if ( $store && defined $message_id ) {
        my $already_recorded = eval { $store->get_message( $chat_id, $message_id, bot_key => $bot_token ) };
        return if !$@ && $already_recorded;

        my $already_queued = eval {
            $store->has_failed_download( $chat_id, $message_id, bot_key => $bot_token )
              || $store->has_failed_transcription( $chat_id, $message_id, bot_key => $bot_token );
        };
        return if !$@ && $already_queued;
    }

    my $caption = $message->{caption};
    my $caption_note =
      defined $caption && length $caption
      ? ' - caption: ' . D2TG::Poller::Format::sanitize_for_stdout($caption)
      : '';

    if ( defined $text && length $text ) {
        my $safe_text = D2TG::Poller::Format::sanitize_for_stdout($text);

        print "$ts NEW TG [$chat_id] $sender: $safe_text$msg_note$reply_ctx\n";
        D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );
        if ( $store && defined $message_id ) {
            D2TG::Poller::Safe::record_message_and_track_offset( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, $safe_text, bot_key => $bot_token );
        }
    }
    elsif ( $media_kind eq 'voice' && $transcribe_voice ) {
        my $file_id = $message->{voice}{file_id};

        print "$ts NEW TG VOICE [$chat_id] $sender: transcribing... (this may take a few minutes)$msg_note\n";

        my ( $ok, $transcript ) =
          _run_non_fatal( $transcribe_voice, $telegram, $file_id, $chat_id, $sender, 'TRANSCRIBE ERROR' );

        if ($ok) {
            my $safe_transcript = D2TG::Poller::Format::sanitize_for_stdout($transcript);

            print "$ts NEW TG VOICE [$chat_id] $sender: $safe_transcript$msg_note$reply_ctx\n";
            D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );
            if ( $store && defined $message_id ) {
                D2TG::Poller::Safe::record_message_and_track_offset( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, $safe_transcript, bot_key => $bot_token );
            }
        }
        elsif ( $store && defined $message_id && defined $file_id ) {
            eval {
                $store->record_failed_transcription(
                    $chat_id, $message_id, $file_id,
                    sender  => $sender,
                    error   => $transcript,
                    bot_key => $bot_token,
                );
            };
            if ($@) {
                my $queue_error = $@;
                $queue_error =~ s/\n\z//;
                print STDERR "TRANSCRIBE ERROR [$chat_id] $sender: "
                  . "failed to queue for retry too: $queue_error\n";
            }
            else {
                print "$ts NEW TG VOICE FAILED [$chat_id] $sender: "
                  . "transcription failed - queued for retry, "
                  . "RETRY WITH: d2 tg.retry-transcription --all"
                  . D2TG::Poller::Format::bot_flag($bot_token) . "\n";
            }
        }
    }
    elsif ( ( $media_kind eq 'photo' || $media_kind eq 'document' ) && $download_media ) {
        my $file_id   = _media_file_id( $message, $media_kind );
        my $file_size = _media_file_size( $message, $media_kind );

        if ( defined $file_size && $file_size > TELEGRAM_GETFILE_MAX_BYTES ) {
            my $mb = sprintf( '%.1f', $file_size / 1024 / 1024 );
            print STDERR "MEDIA DOWNLOAD ERROR [$chat_id] $sender: file too large to download "
              . "(${mb}MB, Telegram's Bot API getFile limit is 20MB)\n";
        }
        else {
            my ( $ok, $result_or_error ) =
              _run_non_fatal( $download_media, $telegram, $file_id, $chat_id, $sender, 'MEDIA DOWNLOAD ERROR' );

            if ($ok) {
                my $local_path = $result_or_error;
                print "$ts NEW TG MEDIA [$chat_id] $sender: $media_kind$caption_note$msg_note$reply_ctx\n";
                D2TG::Poller::Format::print_attachment_template( $chat_id, $message_id ) if defined $message_id;
                D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );
                if ( $store && defined $message_id ) {
                    D2TG::Poller::Safe::record_message_and_track_offset( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note", local_path => $local_path, bot_key => $bot_token );
                }
            }
            elsif ( $store && defined $message_id && defined $file_id ) {
                eval {
                    $store->record_failed_download(
                        $chat_id, $message_id, $file_id,
                        sender       => $sender,
                        media_kind   => $media_kind,
                        caption_note => $caption_note,
                        error        => $result_or_error,
                        bot_key      => $bot_token,
                    );
                };
                if ($@) {
                    my $queue_error = $@;
                    $queue_error =~ s/\n\z//;
                    print STDERR "MEDIA DOWNLOAD ERROR [$chat_id] $sender: "
                      . "failed to queue for retry too: $queue_error\n";
                }
                else {
                    print "$ts NEW TG MEDIA FAILED [$chat_id] $sender: "
                      . "$media_kind$caption_note - queued for retry, "
                      . "RETRY WITH: d2 tg.retry-download --all"
                      . D2TG::Poller::Format::bot_flag($bot_token) . "\n";
                }
            }
        }
    }
    else {
        print "$ts NEW TG MEDIA [$chat_id] $sender: $media_kind$caption_note$msg_note$reply_ctx\n";
        D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );

        if ( $store && defined $message_id ) {
            D2TG::Poller::Safe::record_message_and_track_offset( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note", bot_key => $bot_token );
        }
    }

    return;
}

sub _media_file_id {
    my ( $message, $media_kind ) = @_;

    return $media_kind eq 'document'
      ? $message->{document}{file_id}
      : $message->{photo}[-1]{file_id};
}

sub _media_file_size {
    my ( $message, $media_kind ) = @_;

    return $media_kind eq 'document'
      ? $message->{document}{file_size}
      : $message->{photo}[-1]{file_size};
}

sub _run_non_fatal {
    my ( $coderef, $telegram, $file_id, $chat_id, $sender, $error_prefix ) = @_;

    my $result = eval { $coderef->( $telegram, $file_id ) };

    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        print STDERR "$error_prefix [$chat_id] $sender: $error\n";
        return ( 0, $error );
    }

    return ( 1, $result );
}

1;
