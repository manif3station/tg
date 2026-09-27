package D2TG::Poller::Dispatch;

use strict;
use warnings;
use D2TG::Poller::Format;
use D2TG::Poller::Safe;

use constant TELEGRAM_GETFILE_MAX_BYTES => 20 * 1024 * 1024;

# TGT-343 (found via a scheduled JOB-004 improvement hunt): a Telegram
# album is delivered as separate updates that all share the same
# message.media_group_id - Telegram groups every part together before
# delivery, so a bot polling at any normal interval already receives
# all of them in the same getUpdates batch. This pure partition step
# is the first increment toward grouping an album into one stdout
# event instead of N - it makes zero changes to handle_plain_update's
# own already-hardened access-control/dedup/offset-tracking logic,
# which a later ticket increment will thread through per-group instead
# of per-update.
#
# A lone update carrying a media_group_id is deliberately still
# standalone (not a 1-item "group") - Telegram's real Bot API never
# sends a genuine 1-part album, and treating a defensive/malformed
# single-part case as standalone keeps this helper's output shape
# simple: a "group" always means 2+ parts to actually combine.
sub partition_media_groups {
    my ($updates) = @_;

    my %by_group;
    for my $update (@$updates) {
        my $media_group_id = $update->{message}{media_group_id};
        push @{ $by_group{$media_group_id} }, $update if defined $media_group_id;
    }

    my @groups;
    my @standalone;
    my %group_emitted;

    for my $update (@$updates) {
        my $media_group_id = $update->{message}{media_group_id};

        if ( defined $media_group_id && @{ $by_group{$media_group_id} } > 1 ) {
            push @groups, $by_group{$media_group_id} unless $group_emitted{$media_group_id}++;
        }
        else {
            push @standalone, $update;
        }
    }

    return ( \@groups, \@standalone );
}

# TGT-313 (found via a JOB-004 improvement hunt, reviewing TGT-312's own
# freshly-shipped diff): handle_plain_update's text branch and
# voice-success branch used to duplicate this exact defined($message_id)
# branching shape - the same duplication that let TGT-311's own
# regression (TGT-312) happen, where one copy got the defined-guard
# added and the other didn't. Both branches now call this one helper
# instead.
sub _announce_and_record {
    my (%args) = @_;
    my ( $ts, $chat_id, $sender, $msg_note, $reply_ctx, $message_id, $label, $safe_content, $store, $offset_cap_ref, $update_id, $bot_token )
      = @args{qw(ts chat_id sender msg_note reply_ctx message_id label safe_content store offset_cap_ref update_id bot_token)};

    if ( defined $message_id ) {
        print "$ts $label [$chat_id] $sender$msg_note$reply_ctx\n";
        D2TG::Poller::Format::print_fetch_template( $chat_id, $message_id );
        D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );
        if ($store) {
            D2TG::Poller::Safe::record_message_and_track_offset( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, $safe_content, bot_key => $bot_token );
        }
    }
    else {
        print "$ts $label [$chat_id] $sender: $safe_content$reply_ctx\n";
        D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );
    }
    return;
}

# TGT-343 (found via a scheduled JOB-004 improvement hunt, extending
# TGT-313's own "found it twice, extract it" precedent one branch
# further): handle_plain_update's downloaded-media and fallback-media
# branches each duplicated this record_message_and_track_offset call
# site in slightly different shapes (one passing local_path, one not).
# Both branches now call this one helper instead - the ternary below
# reproduces each branch's own exact prior argument list unchanged.
#
# group_collect_ref is optional and undef by every existing caller
# today: when absent, behavior is byte-for-byte identical to before
# this ticket (the announce prints exactly as it always did). When
# present (only true once a future handle_media_group_update starts
# passing it, one call per album part), the individual stdout announce
# is suppressed and a summary of this part is pushed onto it instead -
# the download/store/offset-tracking above is unaffected either way.
sub _record_media_and_announce {
    my (%args) = @_;
    my ( $ts, $chat_id, $sender, $msg_note, $reply_ctx, $message_id, $media_kind, $caption_note, $store, $offset_cap_ref, $update_id, $bot_token, $local_path, $group_collect_ref )
      = @args{qw(ts chat_id sender msg_note reply_ctx message_id media_kind caption_note store offset_cap_ref update_id bot_token local_path group_collect_ref)};

    if ( $store && defined $message_id ) {
        D2TG::Poller::Safe::record_message_and_track_offset(
            $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note",
            ( defined $local_path ? ( local_path => $local_path ) : () ),
            bot_key => $bot_token,
        );
    }

    if ($group_collect_ref) {
        push @$group_collect_ref, { chat_id => $chat_id, message_id => $message_id, media_kind => $media_kind, caption_note => $caption_note };
    }
    else {
        print "$ts NEW TG MEDIA [$chat_id] $sender: $media_kind$caption_note$msg_note$reply_ctx\n";
        D2TG::Poller::Format::print_attachment_template( $chat_id, $message_id ) if defined $message_id && defined $local_path;
        D2TG::Poller::Format::print_reply_template( $chat_id, $message_id, $bot_token );
    }
    return;
}

# TGT-327 (found via a live JOB-004 improvement hunt): handle_plain_update's
# voice-transcription-failure branch and photo/document-download-failure
# branch used to duplicate this exact shape - eval-wrap a call to
# record_failed_X, then on $@ print an ERROR-PREFIX "failed to queue for
# retry too" line to STDERR, else print a success line naming the retry
# command. Both branches now call this one helper instead, differing only
# in which record call they pass (via a coderef, since the two store
# methods take different arguments) and their own kind-specific text.
sub _queue_failed_and_report {
    my (%args) = @_;
    my ( $record_coderef, $error_prefix, $ts, $chat_id, $sender, $success_label, $success_note, $retry_command, $bot_token )
      = @args{qw(record_coderef error_prefix ts chat_id sender success_label success_note retry_command bot_token)};

    eval { $record_coderef->() };
    if ($@) {
        my $queue_error = $@;
        $queue_error =~ s/\n\z//;
        print STDERR "$error_prefix [$chat_id] $sender: "
          . "failed to queue for retry too: $queue_error\n";
    }
    else {
        print "$ts $success_label [$chat_id] $sender: "
          . "$success_note - queued for retry, "
          . "RETRY WITH: $retry_command"
          . D2TG::Poller::Format::bot_flag($bot_token) . "\n";
    }
    return;
}

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
    my ( $update, $update_id, $offset_cap_ref, $telegram, $store, $bot_token, $transcribe_voice, $download_media, $group_collect_ref ) = @_;

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

        # TGT-311 (explicit user-requested architecture change): this
        # message's OWN content is no longer printed inline here - only
        # the announce line plus a FETCH WITH command. d2 tg.fetch
        # reveals the content (already recorded below via
        # record_message_and_track_offset, unchanged) and marks the
        # message read as a side effect of a successful fetch.
        # reply_ctx (a DIFFERENT, already-existing message's own
        # context - what THIS message is replying to) is deliberately
        # left unchanged/still printed - out of scope, never asked for,
        # and it already goes through the same stored-summary/fetch-once
        # discipline via stored_summary's own store lookup.
        #
        # TGT-312 (found via a JOB-003 hourly bug hunt, reproduced live
        # in the perl-test container): without a message_id, neither
        # print_fetch_template nor record_message_and_track_offset can
        # run at all (both require it) - a message genuinely missing
        # message_id (a malformed/defensive payload shape; Telegram's
        # real Bot API always sets it, but several existing test
        # fixtures already model its absence) would otherwise vanish
        # completely: never shown inline (TGT-311 removed that), never
        # stored, no FETCH WITH command to name it by. Falls back to
        # printing the content inline in that one case - the only way
        # left to avoid losing it outright. TGT-313: this branching now
        # lives in the shared _announce_and_record helper (above), used
        # by both this branch and the voice-success branch below.
        _announce_and_record(
            ts             => $ts,
            chat_id        => $chat_id,
            sender         => $sender,
            msg_note       => $msg_note,
            reply_ctx      => $reply_ctx,
            message_id     => $message_id,
            label          => 'NEW TG',
            safe_content   => $safe_text,
            store          => $store,
            offset_cap_ref => $offset_cap_ref,
            update_id      => $update_id,
            bot_token      => $bot_token,
        );
    }
    elsif ( $media_kind eq 'voice' && $transcribe_voice ) {
        my $file_id = $message->{voice}{file_id};

        print "$ts NEW TG VOICE [$chat_id] $sender: transcribing... (this may take a few minutes)$msg_note\n";

        my ( $ok, $transcript ) =
          _run_non_fatal( $transcribe_voice, $telegram, $file_id, $chat_id, $sender, 'TRANSCRIBE ERROR' );

        if ($ok) {
            my $safe_transcript = D2TG::Poller::Format::sanitize_for_stdout($transcript);

            # TGT-311 (explicit user-requested architecture change):
            # the transcript is no longer printed inline here either -
            # only the announce line plus a FETCH WITH command,
            # matching the plain-text branch above exactly. reply_ctx
            # (a different message's own context) is left unchanged,
            # same reasoning as the text branch above.
            #
            # TGT-312 (found via a JOB-003 hourly bug hunt, reproduced
            # live): same fallback as the plain-text branch above -
            # without message_id, print_fetch_template/record_message_
            # and_track_offset can't run at all, so the transcript
            # would vanish completely rather than merely go unfetchable
            # by id. Falls back to inline printing in that one case.
            # TGT-313: this branching now lives in the shared
            # _announce_and_record helper (top of file), same as the
            # plain-text branch above.
            _announce_and_record(
                ts             => $ts,
                chat_id        => $chat_id,
                sender         => $sender,
                msg_note       => $msg_note,
                reply_ctx      => $reply_ctx,
                message_id     => $message_id,
                label          => 'NEW TG VOICE',
                safe_content   => $safe_transcript,
                store          => $store,
                offset_cap_ref => $offset_cap_ref,
                update_id      => $update_id,
                bot_token      => $bot_token,
            );
        }
        elsif ( $store && defined $message_id && defined $file_id ) {
            _queue_failed_and_report(
                record_coderef => sub {
                    $store->record_failed_transcription(
                        $chat_id, $message_id, $file_id,
                        sender  => $sender,
                        error   => $transcript,
                        bot_key => $bot_token,
                    );
                },
                error_prefix  => 'TRANSCRIBE ERROR',
                ts            => $ts,
                chat_id       => $chat_id,
                sender        => $sender,
                success_label => 'NEW TG VOICE FAILED',
                success_note  => 'transcription failed',
                retry_command => 'd2 tg.retry-transcription --all',
                bot_token     => $bot_token,
            );
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
                _record_media_and_announce(
                    ts             => $ts,
                    chat_id        => $chat_id,
                    sender         => $sender,
                    msg_note       => $msg_note,
                    reply_ctx      => $reply_ctx,
                    message_id     => $message_id,
                    media_kind     => $media_kind,
                    caption_note   => $caption_note,
                    store          => $store,
                    offset_cap_ref => $offset_cap_ref,
                    update_id      => $update_id,
                    bot_token      => $bot_token,
                    local_path     => $local_path,
                    group_collect_ref => $group_collect_ref,
                );
            }
            elsif ( $store && defined $message_id && defined $file_id ) {
                _queue_failed_and_report(
                    record_coderef => sub {
                        $store->record_failed_download(
                            $chat_id, $message_id, $file_id,
                            sender       => $sender,
                            media_kind   => $media_kind,
                            caption_note => $caption_note,
                            error        => $result_or_error,
                            bot_key      => $bot_token,
                        );
                    },
                    error_prefix  => 'MEDIA DOWNLOAD ERROR',
                    ts            => $ts,
                    chat_id       => $chat_id,
                    sender        => $sender,
                    success_label => 'NEW TG MEDIA FAILED',
                    success_note  => "$media_kind$caption_note",
                    retry_command => 'd2 tg.retry-download --all',
                    bot_token     => $bot_token,
                );
            }
        }
    }
    else {
        _record_media_and_announce(
            ts             => $ts,
            chat_id        => $chat_id,
            sender         => $sender,
            msg_note       => $msg_note,
            reply_ctx      => $reply_ctx,
            message_id     => $message_id,
            media_kind     => $media_kind,
            caption_note   => $caption_note,
            store          => $store,
            offset_cap_ref => $offset_cap_ref,
            update_id      => $update_id,
            bot_token      => $bot_token,
            group_collect_ref => $group_collect_ref,
        );
    }

    return;
}

# TGT-343 (found via a scheduled JOB-004 improvement hunt): called once
# per media_group_id group formed by partition_media_groups (a real
# Telegram album - 2+ photos/documents sent together sharing one
# media_group_id). Runs handle_plain_update on every member exactly as
# a standalone update would be, so access control, dedup, download,
# storage and offset-tracking are unchanged and fully reused - only
# passes group_collect_ref so each member's own individual stdout
# announce is suppressed, then prints ONE combined NEW TG MEDIA ALBUM
# line (naming every message_id collected) plus one GET ATTACHMENT WITH
# per part plus one shared reply template, instead of N separate
# announces.
sub handle_media_group_update {
    my ( $group, $offset_cap_ref, $telegram, $store, $bot_token, $download_media ) = @_;

    return unless @$group;

    my @collected;
    for my $update (@$group) {
        my $update_id = $update->{update_id};
        handle_plain_update( $update, $update_id, $offset_cap_ref, $telegram, $store, $bot_token, undef, $download_media, \@collected );
    }

    return unless @collected;

    my $first_message = $group->[0]{message};
    my $chat_id        = $first_message->{chat}{id};
    my $sender         = D2TG::Poller::Format::display_name( $chat_id, $first_message->{from}{username} );
    $sender = D2TG::Poller::Format::format_forwarded_sender( $sender, $first_message->{forward_origin} );
    my $ts = D2TG::Poller::Format::timestamp_prefix($first_message);

    my $count      = scalar(@collected);
    my $media_kind = $collected[0]{media_kind};
    my $msg_ids    = join( ', ', map { "#$_->{message_id}" } grep { defined $_->{message_id} } @collected );
    my $msg_note   = length($msg_ids) ? " (msgs $msg_ids)" : '';

    print "$ts NEW TG MEDIA ALBUM [$chat_id] $sender: $count x $media_kind$msg_note\n";
    for my $item (@collected) {
        D2TG::Poller::Format::print_attachment_template( $item->{chat_id}, $item->{message_id} ) if defined $item->{message_id};
    }
    D2TG::Poller::Format::print_reply_template( $chat_id, $collected[0]{message_id}, $bot_token );

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
