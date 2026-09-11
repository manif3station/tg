package D2TG::Poller;

use strict;
use warnings;
use POSIX qw(strftime);
use D2TG::Config;
use D2TG::Store;

use constant TELEGRAM_GETFILE_MAX_BYTES => 20 * 1024 * 1024;

# TGT-186 (found via a scheduled JOB-003 hourly bug hunt, reproduced live
# against cli/history.pl): 7 cli/*.pl scripts (attachment, text-only-
# replies, approve, retry-download, history, reply, unread) each
# construct D2TG::Store->new unwrapped, sharing the identical raw-crash/
# db-path-leak risk TGT-183 already fixed for cli/poller.pl's own call.
# All 7 (plus poller.pl's own pre-TGT-183 shape) built the same
# db_path shape and eval/classify/refuse pattern - poller.pl passes
# admin_chat_id as an arrayref of every configured group's chat_id,
# these 7 pass a plain scalar, not byte-identical args - so this is a
# shared helper (this sub takes admin_chat_id opaquely, whatever shape
# the caller passes through) rather than 7 separate eval-wraps,
# matching this project's own TGT-167/170/171/172/177 precedent for
# exactly this class of duplication. Returns the open store on
# success; on failure, prints the identical scrubbed refusal TGT-183
# established and exits 1 - never returns in that case.
sub open_store_or_die {
    my (%args) = @_;

    my $store = eval {
        D2TG::Store->new(
            db_path => D2TG::Config::state_db_path(
                default_root => $args{skill_root},
                base_dir     => $args{base_dir},
            ),
            admin_chat_id => $args{admin_chat_id},
        );
    };
    if ($@) {
        my $reason = _classify_store_error($@);
        print STDERR "Failed to open local storage ($reason) - refusing to start.\n";
        exit 1;
    }
    return $store;
}

sub run_once_safe {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $sleep_fn = delete $opts{sleep} || \&_sleep;

    my $new_offset = eval {
        my ( undef, $off ) = run_once( $telegram, $offset, $store, %opts );
        $off;
    };

    if ($@) {
        my $error = $@;
        unless ( D2TG::Config::is_transient_error($error) ) {
            $error =~ s/\n\z//;
            print STDERR "POLL ERROR: $error\n";
        }
        $sleep_fn->(2);
        return $offset;
    }

    return $new_offset;
}

sub _sleep {
    my ($seconds) = @_;
    return sleep $seconds;
}

sub run_once {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $transcribe_voice = $opts{transcribe_voice};
    my $download_media   = $opts{download_media};
    my $bot_token        = $opts{bot_token};

    my ( $updates, $next_offset ) = $telegram->get_updates( offset => $offset );

    # TGT-178 (Michael's Q-011 ruling on TGT-176's message-loss
    # investigation): _record_message_safe (TGT-132) treats a store
    # write failure as non-fatal, but the offset used to advance past
    # the failed update regardless - Telegram never redelivers an
    # update once the offset has moved past it, so that message's
    # local history was permanently, silently lost. Track the first
    # update_id (in iteration order, which is also the earliest, since
    # Telegram delivers updates in increasing update_id order) whose
    # record_message call failed; if any did, cap the returned offset
    # there below instead of the batch's
    # own full next offset, so Telegram redelivers that update (and
    # everything after it in the same batch) next cycle.
    my $offset_cap;

    for my $update (@$updates) {
        my $update_id = $update->{update_id};

        # TGT-143 (live Telegram question, msg #176, Michael: "the user
        # can give a like or mark a message with emoji, is that
        # something can be implement to pick this up"): detection/
        # printing only, per the ticket's own scope - no reply action
        # taken on a reaction, matching the existing pattern for every
        # other inbound event this poller only ever reports.
        if ( my $reaction = $update->{message_reaction} ) {
            my $chat_id = $reaction->{chat}{id};

            # TGT-151 (JOB-003 scheduled hourly bug hunt finding): this
            # branch previously ran entirely before the is_allowed gate
            # below, which only guarded the plain message/media branch -
            # any chat_id, including one never approved and not even
            # pending, could react and have it printed unconditionally,
            # leaking its chat_id/username onto the monitored stream.
            # Reuses the exact same gate the message branch uses; no
            # add_pending here since a reaction isn't a first-contact
            # event the way a message is.
            #
            # TGT-165 (found via a scheduled hourly bug-hunt): is_allowed
            # runs against a RaiseError=>1 DBI handle, so a locked/busy
            # SQLite database makes it die - unwrapped, that propagated
            # uncaught out of run_once, aborting the whole poll batch and
            # (since run_once_safe preserves the pre-batch offset on
            # error) causing the ENTIRE batch, including already-printed
            # updates, to be redelivered and reprinted next cycle - the
            # same failure class TGT-132 already fixed once for
            # record_message. Skip this update non-fatally on error.
            if ($store) {
                my $allowed = eval { $store->is_allowed( $chat_id, $bot_token ) };
                if ($@) {
                    # TGT-193 (found via a scheduled JOB-004 improvement
                    # hunt): this call site predates _classify_store_error
                    # (TGT-165, before TGT-167 extracted the shared
                    # helper) and was never revisited - it echoed the raw
                    # exception text verbatim, unlike every other
                    # D2TG::Store-write error path in this codebase
                    # (_record_message_safe, persist_offset_safe,
                    # D2TG::Reply's _store_write_safe). A raw DBI/SQLite
                    # error can embed the database file's own real path.
                    my $reason = _classify_store_error($@);
                    print STDERR "STORE ERROR [$chat_id]: is_allowed failed - $reason\n";
                    next;
                }
                next unless $allowed;
            }

            my $message_id = $reaction->{message_id};

            # TGT-154 (JOB-003 scheduled hourly bug hunt finding):
            # MessageReactionUpdated's own 'user' field is optional -
            # an anonymous chat/channel reaction (e.g. a channel admin
            # reacting as the channel itself) omits 'user' entirely and
            # supplies 'actor_chat' (a Chat object) instead. Same
            # failure class TGT-142 already fixed once for
            # forward_origin's own sender_chat/chat fields.
            my $sender =
              $reaction->{actor_chat}
              ? _sanitize_for_stdout(
                $reaction->{actor_chat}{title} // $reaction->{actor_chat}{username} // 'unknown' )
              : _sanitize_for_stdout( _display_name( $chat_id, $reaction->{user}{username} ) );

            # A Codex review finding: MessageReactionUpdated reports
            # the FULL current/previous reaction sets, not a single
            # before/after pair - a user can have multiple reactions on
            # one message, and a change can add one emoji while
            # removing another in the same update. Diff old vs new
            # rather than assuming any non-empty new_reaction means
            # "the" reaction was added.
            #
            # A second Codex finding: ReactionType is a tagged union -
            # type=emoji carries an emoji character, but type=custom_emoji
            # (a distinct custom_emoji_id) and type=paid carry no emoji
            # field at all. Keying/diffing on emoji alone collapsed every
            # non-standard reaction to the same 'unknown' bucket, silently
            # hiding a real change between two different custom emojis
            # (both mapping to 'unknown' -> 'unknown' looks like no
            # change at all). Key on type+id instead, printed label
            # falls back to a description when there's no emoji glyph.
            my %old_by_key = map { _reaction_key($_) => _reaction_label($_) } @{ $reaction->{old_reaction} // [] };
            my %new_by_key = map { _reaction_key($_) => _reaction_label($_) } @{ $reaction->{new_reaction} // [] };

            for my $key ( sort grep { !$old_by_key{$_} } keys %new_by_key ) {
                print "NEW TG REACTION [$chat_id] $sender: "
                  . _sanitize_for_stdout( $new_by_key{$key} ) . " on message $message_id\n";
            }
            for my $key ( sort grep { !$new_by_key{$_} } keys %old_by_key ) {
                print "REACTION REMOVED [$chat_id] $sender: "
                  . _sanitize_for_stdout( $old_by_key{$key} ) . " on message $message_id\n";
            }
            next;
        }

        # TGT-169 (live Telegram question, msg #246, Michael: "is the
        # implementable if the user on telegram edit the previous
        # message and that will notify the agent about the updated
        # message"): Telegram sends a distinct edited_message update
        # (same shape as an ordinary message, reflecting the post-edit
        # content) generally when a message known to the bot in an
        # allow-listed chat is edited - genuinely detectable, unlike
        # deletion of an ordinary chat message (no such update exists
        # for that in the Bot API at all; a business-connection-scoped
        # deleted_business_messages update exists for a different,
        # unrelated feature this project doesn't use). Gated by the
        # same is_allowed check every other branch uses (checked by
        # chat_id, same as every other branch); no add_pending,
        # matching message_reaction's own precedent above - an edit
        # isn't a first-contact event, the original message already
        # established (or failed to establish) contact. A text edit's
        # new content is recorded via record_message so d2 tg.history
        # reflects it, consistent with that function's own history-
        # tracking purpose (unlike a reaction, which changes nothing
        # about the message's own content) - a caption/media-only edit
        # (no text) is still announced but not recorded, to avoid
        # overwriting an already-correct history summary with nothing
        # useful; recording those too is a narrower follow-up, not
        # this ticket's own scope.
        if ( my $edited = $update->{edited_message} ) {
            my $chat_id = $edited->{chat}{id};

            if ($store) {
                my $allowed = eval { $store->is_allowed( $chat_id, $bot_token ) };
                if ($@) {
                    # TGT-193 (found via a scheduled JOB-004 improvement
                    # hunt): this call site predates _classify_store_error
                    # (TGT-165, before TGT-167 extracted the shared
                    # helper) and was never revisited - it echoed the raw
                    # exception text verbatim, unlike every other
                    # D2TG::Store-write error path in this codebase
                    # (_record_message_safe, persist_offset_safe,
                    # D2TG::Reply's _store_write_safe). A raw DBI/SQLite
                    # error can embed the database file's own real path.
                    my $reason = _classify_store_error($@);
                    print STDERR "STORE ERROR [$chat_id]: is_allowed failed - $reason\n";
                    next;
                }
                next unless $allowed;
            }

            my $sender      = _display_name( $chat_id, $edited->{from}{username} );
            my $message_id  = $edited->{message_id};
            my $edited_text = $edited->{text};
            my $has_text    = defined $edited_text && length $edited_text;
            my $safe_text   = $has_text ? _sanitize_for_stdout($edited_text) : '(no text)';
            my $ts = _timestamp_prefix($edited);

            print "$ts NEW TG EDIT [$chat_id] $sender: $safe_text (msg #$message_id, edited)\n";

            # Codex review finding: a caption/media-only edit (no
            # $edited->{text} at all - a text edit is the only kind
            # this narrow ticket handles) would otherwise overwrite an
            # already-correct history summary with the literal string
            # '(no text)', corrupting it. Only record when there is
            # real text to record; the edit is still announced either
            # way, just not (yet) reflected in d2 tg.history when it's
            # a caption/media change.
            if ( $store && defined $message_id && $has_text ) {
                _record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, $safe_text );
            }

            # TGT-178 KNOWN GAP (Codex review finding): this branch
            # does NOT get the plain-message dedupe check below, so if
            # a batch-level offset cap (from an EARLIER sibling update
            # failing to record) causes THIS edit to be redelivered
            # after it already succeeded, it WILL be re-announced.
            # Deliberately out of scope: the plain-message dedupe keys
            # only on (chat_id, message_id), which for an edit would
            # also suppress a genuinely NEW future edit to the same
            # message - correctly detecting "this exact edit, not a
            # later one, was already announced" needs update_id-level
            # delivery tracking, a larger change than this ticket's
            # own scope. A follow-up ticket is the right place for
            # edit-level dedupe if a real duplicate-edit incident
            # (as opposed to this theoretical redelivery window)
            # is ever reported.
            next;
        }

        my $message = $update->{message} or next;
        my $text       = $message->{text};
        my $media_kind = _media_kind($message);

        next unless ( defined $text && length $text ) || $media_kind;

        my $chat_id = $message->{chat}{id};
        my $sender  = _display_name( $chat_id, $message->{from}{username} );

        # TGT-142 (live Telegram question, msg #170, answered by
        # Michael msg #173: "use the origin name instead of user id"):
        # when B forwards A's message, $message->{from} names B (the
        # forwarder), never A (the original author). Telegram's Bot
        # API's forward_origin field, already reaching this untouched
        # (D2TG::Telegram::get_updates strips nothing), names A when
        # present - not an unavoidable platform limitation, just a
        # previously-unread field.
        $sender = _format_forwarded_sender( $sender, $message->{forward_origin} );

        my $ts = _timestamp_prefix($message);

        if ($store) {

            # TGT-165 (found via a scheduled hourly bug-hunt): both
            # is_allowed and add_pending run against a RaiseError=>1 DBI
            # handle, so a locked/busy SQLite database makes either die -
            # unwrapped, that propagated uncaught out of run_once,
            # aborting the whole poll batch and (since run_once_safe
            # preserves the pre-batch offset on error) causing the
            # ENTIRE batch, including already-printed updates, to be
            # redelivered and reprinted next cycle - the same failure
            # class TGT-132 already fixed once for record_message. Skip
            # this update non-fatally on either call's error.
            my $allowed = eval { $store->is_allowed( $chat_id, $bot_token ) };
            if ($@) {
                # TGT-193: see the same fix's comment on the
                # message_reaction/edited_message branches above.
                my $reason = _classify_store_error($@);
                print STDERR "STORE ERROR [$chat_id]: is_allowed failed - $reason\n";
                next;
            }

            unless ($allowed) {
                my $added = eval { $store->add_pending( $chat_id, $bot_token ) };
                if ($@) {
                    # TGT-193: same fix as is_allowed above.
                    my $reason = _classify_store_error($@);
                    print STDERR "STORE ERROR [$chat_id]: add_pending failed - $reason\n";
                    next;
                }
                if ($added) {
                    print "$ts NEW TG PENDING [$chat_id] awaiting approval\n";
                }
                next;
            }
        }

        my $reply_ctx  = _reply_context_suffix( $message, $store, $chat_id );
        my $message_id = $message->{message_id};
        my $msg_note   = defined $message_id ? " (msg #$message_id)" : '';

        # TGT-178: this update is only being seen again because
        # Telegram redelivered it - an EARLIER sibling in that same
        # original batch failed to record and capped the offset below
        # it (see $offset_cap above). If THIS update was already
        # successfully recorded on a prior cycle, skip announcing/
        # acting on it entirely rather than printing a duplicate NEW
        # TG/re-downloading/re-transcribing something the watching
        # agent has already seen. A transient lookup error here is
        # treated as "not previously recorded" (proceed as normal) -
        # a rare duplicate announcement is a smaller cost than
        # silently dropping a message this check can't confirm either
        # way, matching this file's established degrade-not-crash
        # philosophy (TGT-165/166/167).
        if ( $store && defined $message_id ) {
            my $already_recorded = eval { $store->get_message( $chat_id, $message_id ) };
            next if !$@ && $already_recorded;
        }

        # TGT-092 (live production incident): a photo/document's caption
        # was never read at all - Telegram's Bot API attaches it as a
        # field separate from $message->{text} (which is only present
        # for plain text messages), so it was silently dropped.
        my $caption = $message->{caption};
        my $caption_note =
          defined $caption && length $caption
          ? ' - caption: ' . _sanitize_for_stdout($caption)
          : '';

        if ( defined $text && length $text ) {
            my $safe_text = _sanitize_for_stdout($text);

            print "$ts NEW TG [$chat_id] $sender: $safe_text$msg_note$reply_ctx\n";
            _print_reply_template( $chat_id, $message_id, $bot_token );
            if ( $store && defined $message_id ) {
                _record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, $safe_text );
            }
        }
        elsif ( $media_kind eq 'voice' && $transcribe_voice ) {
            my $file_id = $message->{voice}{file_id};

            # TGT-100 (live user request): transcription can genuinely
            # take several real minutes (a slow local Whisper run), and
            # it blocks this poll cycle the whole time. Printing this
            # notice BEFORE the blocking call, not only the final NEW TG
            # VOICE line after, lets the watching agent notice
            # immediately and tell the sender "got it, processing"
            # instead of the whole wait being silent.
            print "$ts NEW TG VOICE [$chat_id] $sender: transcribing... (this may take a few minutes)$msg_note\n";

            my ( $ok, $transcript ) =
              _run_non_fatal( $transcribe_voice, $telegram, $file_id, $chat_id, $sender, 'TRANSCRIBE ERROR' );

            if ($ok) {
                my $safe_transcript = _sanitize_for_stdout($transcript);

                print "$ts NEW TG VOICE [$chat_id] $sender: $safe_transcript$msg_note$reply_ctx\n";
                _print_reply_template( $chat_id, $message_id, $bot_token );
                if ( $store && defined $message_id ) {
                    _record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, $safe_transcript );
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
                    _print_attachment_template( $chat_id, $message_id ) if defined $message_id;
                    _print_reply_template( $chat_id, $message_id, $bot_token );
                    if ( $store && defined $message_id ) {
                        _record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note", local_path => $local_path );
                    }
                }
                elsif ( $store && defined $message_id && defined $file_id ) {

                    # TGT-104 (user-supplied feature-gap analysis): a
                    # transient download failure (a network hiccup mid-
                    # transfer, a momentary server error) used to be
                    # reported once and forgotten - no way to retry it
                    # later. Persist enough to retry AND to fully
                    # restore the message into history on a successful
                    # retry later (sender/media_kind/caption_note, the
                    # same pieces record_message's own success-path
                    # summary is built from above).
                    #
                    # Wrapped in eval (Codex review finding): this queue
                    # write is itself non-fatal, exactly like the
                    # download failure it's recording - a locked/full
                    # SQLite database must not turn an already-reported,
                    # already-non-fatal media error into a poll-cycle
                    # failure that could cause this same update to be
                    # redelivered.
                    eval {
                        $store->record_failed_download(
                            $chat_id, $message_id, $file_id,
                            sender       => $sender,
                            media_kind   => $media_kind,
                            caption_note => $caption_note,
                            error        => $result_or_error,
                        );
                    };
                    if ($@) {
                        my $queue_error = $@;
                        $queue_error =~ s/\n\z//;
                        print STDERR "MEDIA DOWNLOAD ERROR [$chat_id] $sender: "
                          . "failed to queue for retry too: $queue_error\n";
                    }
                }
            }
        }
        else {
            print "$ts NEW TG MEDIA [$chat_id] $sender: $media_kind$caption_note$msg_note$reply_ctx\n";
            _print_reply_template( $chat_id, $message_id, $bot_token );

            # TGT-120 (found via a scheduled bug-hunt): unlike every
            # other successful branch above (text, transcribed voice,
            # downloaded photo/document), this fallback (a photo/
            # document/voice message with no download_media/
            # transcribe_voice callback given) never recorded the
            # message in the store, making it invisible to
            # d2 tg.history/d2 tg.unread afterward even though it was
            # printed to stdout in real time.
            if ( $store && defined $message_id ) {
                _record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note" );
            }
        }
    }

    # TGT-178: if any update's record_message call failed, cap the
    # returned offset there instead of the batch's own full next
    # offset - see $offset_cap's own comment above the loop.
    if ( defined $offset_cap && ( !defined $next_offset || $offset_cap < $next_offset ) ) {
        $next_offset = $offset_cap;
    }

    return ( $updates, $next_offset );
}

sub _record_message_safe {
    my ( $store, @args ) = @_;

    # TGT-132: matching D2TG::Store::record_failed_download's own
    # eval-wrap (TGT-104) and its stated reason - a locked/full SQLite
    # database (a real possibility even after TGT-129's busy_timeout, if
    # contention outlasts it) must not turn an already-printed/already-
    # handled update into a die that aborts the rest of this batch:
    # run_once_safe would catch it by returning the offset UNCHANGED,
    # causing the WHOLE batch (including updates already announced) to
    # be redelivered and reprinted next cycle.
    #
    # TGT-178: now returns a true/false success flag instead of void,
    # so run_once can cap the offset at this update instead of letting
    # it advance past a message whose local record was never written.
    local $@;
    eval { $store->record_message(@args) };
    if ($@) {
        # Codex review finding: the raw exception text was previously
        # printed verbatim - a DBI/SQLite error can embed the database
        # file's own path (e.g. "unable to open database file: ..."),
        # which this project has just spent TGT-133 closing off as an
        # information-disclosure surface elsewhere. Classify into a
        # short, fixed reason instead of ever echoing $@ itself.
        my $reason = _classify_store_error($@);
        print STDERR "record_message failed ($reason) - message was already printed/handled, only its own store record is affected\n";
        return 0;
    }
    return 1;
}

sub _record_message_and_track_offset {
    my ( $store, $offset_cap_ref, $update_id, @record_message_safe_args ) = @_;

    # TGT-181 (found via a scheduled improvement hunt): the 2-line
    # "call _record_message_safe, cap $offset_cap on failure" pattern
    # TGT-178 introduced appeared identically at all 5 call sites in
    # run_once - extracted here, matching this project's own
    # established "found it twice, extract it" convention
    # (TGT-167/170/171/172/177). $offset_cap_ref is a scalar ref, not a
    # plain return value, because run_once's own $offset_cap must
    # persist and combine ACROSS multiple calls to this helper within
    # one run_once invocation (the first failure across up to 5
    # separate call sites wins) - a return value alone would make
    # every call site re-implement the same "cap on first failure"
    # comparison this helper exists to remove.
    my $recorded = _record_message_safe( $store, @record_message_safe_args );
    $$offset_cap_ref = $update_id if !$recorded && !defined $$offset_cap_ref;
    return $recorded;
}

sub _classify_store_error {
    my ($error) = @_;

    # TGT-167 (found via a scheduled improvement hunt): extracted after
    # this exact 4-line ternary was found duplicated verbatim in both
    # _record_message_safe above and persist_offset_safe below, matching
    # this project's own established "found it twice, extract it"
    # convention (e.g. shift_flag_value, TGT-072). Pure duplication
    # removal - the four classified strings and every caller's own
    # surrounding message text are unchanged.
    return
        $error =~ /database is locked/i ? 'database is locked'
      : $error =~ /database.*busy/i     ? 'database is busy'
      : $error =~ /readonly/i           ? 'database is readonly'
      :                                    'an unexpected error';
}

sub persist_offset_safe {
    my ( $store, $offset, $bot_key ) = @_;

    # TGT-191 (live production incident, reported via the budget
    # project: 2 real messages permanently lost): this now returns a
    # true/false success flag (previously void, always) - cli/poller.pl's
    # main loop uses it to decide whether it is safe to advance the
    # in-memory offset that will be sent to Telegram on the NEXT
    # getUpdates call. Telegram forgets/never redelivers an update once
    # a LATER offset has been sent to it - so advancing the in-memory
    # offset unconditionally (the pre-TGT-191 behavior) let the next
    # getUpdates call confirm receipt of a batch to Telegram even when
    # that batch was never durably persisted locally; if the process
    # then crashed (for any reason) before persist_offset_safe next
    # succeeded, the gap between the stale on-disk offset and the
    # already-confirmed-to-Telegram one was permanently unrecoverable.
    # Undefined-offset (nothing to persist) is not a failure - returns
    # true so the caller's own no-op guard still behaves as before.
    return 1 unless defined $offset;

    # TGT-166 (found via a scheduled hourly bug-hunt, a direct follow-up
    # sweep after TGT-165 for the same unwrapped-DBI-call pattern):
    # cli/poller.pl's main loop used to call $store->set_offset(...)
    # directly, with no eval wrapper. Unlike run_once's own calls
    # (TGT-165), this one sits at the top level of the persistent
    # poller script's main loop - not inside run_once_safe's own eval -
    # so a locked/busy SQLite database crashed the ENTIRE poller
    # process, not just one poll cycle's batch. The poll cycle itself
    # already completed successfully via run_once_safe by the time this
    # runs, so losing only this one offset persistence is the right
    # degradation, matching _record_message_safe's own philosophy.
    #
    # TGT-191 update: the comment here previously said a later poll
    # cycle would persist its own "by then newer" offset instead of
    # retrying this exact value - that was only true because the
    # caller used to advance its in-memory offset unconditionally.
    # Since TGT-191 makes the caller hold the in-memory offset back on
    # a false return here, a later cycle now retries persisting THIS
    # SAME offset (or an even earlier one), not a newer one - and the
    # corresponding getUpdates call is correspondingly re-issued with
    # the same, still-unconfirmed-to-Telegram offset, so nothing in
    # that retried batch is lost even if persistence keeps failing.
    local $@;
    eval { $store->set_offset( $offset, $bot_key ) };
    if ($@) {

        # Classify into a short, fixed reason rather than ever echoing
        # $@ itself (TGT-133 precedent - a DBI/SQLite error can embed
        # the database file's own path). Shared with _record_message_safe
        # above via _classify_store_error (TGT-167).
        my $reason = _classify_store_error($@);
        print STDERR "set_offset failed ($reason) - this poll cycle's offset was not persisted; the in-memory offset is not advanced, so a later cycle retries this same offset (TGT-191)\n";
        return 0;
    }
    return 1;
}

# TGT-175 (live production incident, reported via the budget project):
# cli/poller.pl's main-loop version-change check called
# D2TG::Config::skill_version() directly, unwrapped - a transient
# window where .env is briefly missing/unreadable during the skill's
# own self-update (an install rewriting the directory mid-flight) was
# fatal to the ENTIRE poller process, not just to that one version
# check, killing the owner's own Telegram channel until a human
# noticed and restarted the job. Matches persist_offset_safe's own
# non-fatal-degradation philosophy above - the poller's core
# message-processing loop does not need to know the skill's version to
# keep running; the check simply runs again next cycle. Deliberately
# does NOT touch D2TG::Config::skill_version itself, nor the poller's
# own startup call to it - a fresh process launch with no readable
# .env at all should still refuse to start loudly, not silently
# proceed with an unknown version; only this periodic re-check, made
# once the process is already running, is safe to degrade.
sub skill_version_check_safe {
    my (%args) = @_;

    my $version = eval { D2TG::Config::skill_version(%args) };
    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        print STDERR "skill_version_check_safe: $error - skipping this cycle's version-change check, will retry next cycle\n";
        return undef;
    }
    return $version;
}

sub _display_name {
    my ( $chat_id, $username ) = @_;

    my $owner_chat_id = D2TG::Config::chat_id();
    my $owner_name    = D2TG::Config::owner_name();

    if (   defined $chat_id
        && defined $owner_chat_id
        && $chat_id eq $owner_chat_id
        && defined $owner_name
        && length $owner_name )
    {
        return $owner_name;
    }

    return $username // 'unknown';
}

sub _reply_context_suffix {
    my ( $message, $store, $chat_id ) = @_;

    my $original = $message->{reply_to_message};
    return '' unless $original;

    my $original_sender = _display_name( $chat_id, $original->{from}{username} );

    # TGT-142: the replied-to message can itself be a forward - same
    # gap, same fix, so a reply-context line never attributes a
    # forwarded message to its forwarder either.
    $original_sender = _format_forwarded_sender( $original_sender, $original->{forward_origin} );

    my $original_message_id = $original->{message_id};
    my $id_note = defined $original_message_id ? " [msg #$original_message_id]" : '';

    my $what = _stored_summary( $store, $chat_id, $original_message_id );

    unless ( defined $what ) {
        my $original_text = $original->{text};
        if ( defined $original_text && length $original_text ) {
            my $safe = _sanitize_for_stdout($original_text);
            $safe = substr( $safe, 0, 5000 ) . '...' if length $safe > 5000;
            $what = $safe;
        }
        else {
            $what = _media_kind($original) // 'message';
        }
    }

    return qq{ (replying to $original_sender$id_note: $what)};
}

sub _stored_summary {
    my ( $store, $chat_id, $message_id ) = @_;

    return undef unless $store && defined $chat_id && defined $message_id;

    my $stored = $store->get_message( $chat_id, $message_id );

    return $stored ? $stored->{summary} : undef;
}

sub _timestamp_prefix {
    my ($message) = @_;

    my $epoch = $message->{date} // time;

    return '[' . strftime( '%Y-%m-%d %H:%M:%S', localtime($epoch) ) . ']';
}

sub _sanitize_for_stdout {
    my ($text) = @_;

    ( my $safe = $text ) =~ s/\r?\n/\\n/g;
    $safe =~ s/[\x00-\x08\x0B-\x1F\x7F]//g;

    return $safe;
}

sub _print_reply_template {
    my ( $chat_id, $message_id, $bot_token ) = @_;

    # TGT-086: never print the real token here - this line reaches the
    # target project's tira.policy.bridge as a monitor-output event
    # (visible to anyone who can read that board), and the token is a
    # real credential (whoever has it can send/receive as that bot).
    # Masked the same way D2TG::Config::masked_token already masks the
    # startup line (TGT-045); the placeholder <MASKED> is intentionally
    # not runnable as-is - see this template's own POD.
    my $bot_flag =
      defined $bot_token
      ? ' --bot ' . D2TG::Config::masked_token($bot_token)
      : '';
    my $reply_flag = defined $message_id ? " --reply-to-message-id $message_id" : '';
    print qq{REPLY WITH: d2 tg.reply $chat_id "..."$bot_flag$reply_flag\n};
    return;
}

sub _print_attachment_template {
    my ( $chat_id, $message_id ) = @_;

    # TGT-133: never print the real local filesystem path here (or
    # persist it into D2TG::Store's own summary text, which
    # cli/history.pl/cli/unread.pl display verbatim) - the same
    # never-expose-the-real-path convention this project's own Tira
    # board already follows for tira.attachment.get. The watching
    # agent fetches the raw bytes via this command instead.
    print "GET ATTACHMENT WITH: d2 tg.attachment $chat_id $message_id\n";
    return;
}

sub _reaction_key {
    my ($reaction) = @_;

    my $type = $reaction->{type} // '';
    return "emoji:@{[ $reaction->{emoji} // '' ]}"               if $type eq 'emoji';
    return "custom_emoji:@{[ $reaction->{custom_emoji_id} // '' ]}" if $type eq 'custom_emoji';
    return 'paid'                                                 if $type eq 'paid';
    return "unknown:$type";
}

sub _reaction_label {
    my ($reaction) = @_;

    my $type = $reaction->{type} // '';
    return $reaction->{emoji}                if $type eq 'emoji' && defined $reaction->{emoji};
    return 'a custom emoji'                  if $type eq 'custom_emoji';
    return 'a paid reaction'                 if $type eq 'paid';
    return 'an unrecognized reaction type';
}

sub _forward_origin_name {
    my ($origin) = @_;

    return undef unless $origin;

    my $type = $origin->{type} // '';

    if ( $type eq 'user' ) {
        my $u = $origin->{sender_user} // {};

        # TGT-142, Michael's own instruction: use the origin's NAME,
        # never the numeric user id - username first (matching
        # _display_name's own convention), first_name as fallback.
        return $u->{username} // $u->{first_name} // 'unknown';
    }
    elsif ( $type eq 'hidden_user' ) {

        # MessageOriginHiddenUser: the original sender's privacy
        # settings withhold their real identity from bots entirely -
        # Telegram supplies only a display name string, no id. Print
        # exactly what Telegram gives, never claim more certainty than
        # the API itself has.
        return $origin->{sender_user_name} // 'unknown (privacy-restricted)';
    }
    elsif ( $type eq 'chat' ) {
        my $c = $origin->{sender_chat} // {};
        return $c->{title} // $c->{username} // 'a chat';
    }
    elsif ( $type eq 'channel' ) {
        my $c = $origin->{chat} // {};
        return $c->{title} // $c->{username} // 'a channel';
    }

    return undef;
}

# TGT-170: extracted after TGT-142 introduced this same four-line
# formatting logic at two call sites (the main message branch and
# _reply_context_suffix's replied-to-message handling; only the
# variable name differed) - matches the established shift_flag_value
# (TGT-072) / _classify_store_error (TGT-167) precedent for this shape
# of duplication.
sub _format_forwarded_sender {
    my ( $sender, $forward_origin ) = @_;

    my $origin_name = _forward_origin_name($forward_origin);
    return $sender unless defined $origin_name;

    return _sanitize_for_stdout($origin_name) . " (forwarded by $sender)";
}

sub _media_kind {
    my ($message) = @_;

    return 'photo'    if $message->{photo};
    return 'document' if $message->{document};
    return 'voice'    if $message->{voice};

    # TGT-161 (found via a scheduled hourly bug hunt): a video message
    # had neither $message->{text} nor a recognized media kind, so it
    # failed run_once's own "next unless text or media_kind" guard and
    # was silently dropped - not printed, not queued pending, not
    # recorded, no stderr line. video_note/audio/animation/sticker are
    # the same failure class but are deliberately out of scope here -
    # see this ticket's own key_details for why.
    return 'video' if $message->{video};

    return undef;
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

1;

=head1 NAME

D2TG::Poller - the long-poll loop connecting D2TG::Telegram to stdout

=head1 SYNOPSIS

    my $offset;
    while (1) {
        ( undef, $offset ) = D2TG::Poller::run_once( $telegram, $offset, $store );
    }

=head1 KNOWN LIMITATION

C<SIGTERM>/C<SIGINT> are only checked between C<get_updates> calls, so
shutdown can be delayed if it's mid-request when the signal arrives.
TGT-035 (a real production incident: this bound previously did not
actually exist - L<D2TG::Telegram>'s default L<LWP::UserAgent> had no
explicit timeout, so a single call could block for up to LWP's own
180s default, not the 30s this section used to claim) fixed the actual
enforcement: D2TG::Telegram's default C<ua> now has an explicit hard
timeout (C<DEFAULT_HARD_TIMEOUT>, 50s as of TGT-066 - originally 35s).
TGT-044 (a second real production incident - LWP's own timeout
did not actually cover a request stuck in the TCP C<connect()> phase,
which not even C<SIGTERM> could interrupt) closed that remaining gap
with an explicit C<SIGALRM>-based hard timeout inside C<_call> itself -
so this delay is now genuinely bounded to C<DEFAULT_HARD_TIMEOUT> in
every case, not merely assumed to be. Interrupting the blocking HTTP call mid-flight
(rather than bounding its maximum duration) would still need an async/
select-based rewrite, which remains out of scope - acceptable now that
the bound is short and actually enforced end to end.

=head1 DESCRIPTION

C<run_once> performs a single C<get_updates> call and, for each update
carrying a text message or recognized media (photo/document/voice/video,
TGT-161) from an allow-listed sender, prints one line to STDOUT: the
message text, or C<NEW TG MEDIA [chat_id] sender: <type>> for
photo/document (and voice too, when no C<transcribe_voice> callback is
given; photo/document too, when no C<download_media> callback is given).
A video always takes this same fallback path regardless of what
callbacks are given, since there is no video-specific handling or
download path at all. A message from a sender
not yet allow-listed produces no content output at all, but does print a
one-time C<NEW TG PENDING [chat_id] awaiting approval> line the first
time that sender is recorded pending (not on subsequent messages from
the same still-pending sender). Replying is separate, later work.

TGT-165 (found via a scheduled hourly bug-hunt): the access-control
gate itself - C<is_allowed> (both the message and message_reaction
branches) and C<add_pending> (message branch) - is C<eval>-wrapped, not
called directly, for the identical reason C<_record_message_safe>
below wraps C<record_message> (TGT-132): both run against a
C<RaiseError=E<gt>1> DBI handle, so a locked/busy SQLite database used
to make either die, aborting the whole batch (and, since
C<run_once_safe> preserves the pre-batch offset on error, causing the
entire batch - including updates already printed earlier in that same
cycle - to be redelivered and reprinted next cycle). A store error at
either call now prints C<STORE ERROR [chat_id]: E<lt>what failedE<gt>
- E<lt>errorE<gt>> to STDERR and skips that one update non-fatally
instead. Deliberate tradeoff (a Codex review point, worth stating
explicitly rather than leaving implicit): "skip" here means the
poller's own C<offset> still advances past that update, same as any
successfully-handled one - the failed update is not retried or
queued, unlike a failed media download (C<record_failed_download>,
TGT-104). A transient lock is expected to be gone by the time
Telegram's own next poll cycle would have redelivered a REAL retry
anyway (this codebase's poll interval is short), so the update is
effectively lost rather than delayed - preferable to the alternative
this ticket fixes (redelivering and reprinting the ENTIRE batch,
including already-handled updates, forever until the lock clears).
C<eval> here also suppresses any other exception C<is_allowed>/
C<add_pending> could raise, not only a locked database - STDERR is the
only signal for those too, matching how every other store-error path
in this module already behaves.

Every successful branch above also records the message in the store
(when one is given and the update carries a C<message_id>) - including
the fallback branch that fires for a photo/document/voice/video message
whose applicable callback (C<download_media> for photo/document,
C<transcribe_voice> for voice, always for video since it has none) was
not given (TGT-120, found via a scheduled bug-hunt: this branch used to
print its C<NEW TG MEDIA> line without recording anything, making that
message invisible to a later C<d2 tg.history>/C<d2 tg.unread> lookup
even though it had already been printed to stdout in real time). Before
TGT-161 (found via a scheduled hourly bug hunt), a video message had
neither plain text nor a recognized media kind - C<_media_kind> only
knew photo/document/voice - so it silently failed C<run_once>'s own
"text or media_kind" guard: not printed, not queued pending, not
recorded, no stderr line, the poll offset still advancing past it.
C<video_note>/C<audio>/C<animation>/C<sticker> are the same failure
class but are deliberately still unrecognized, deferred to a follow-up
ticket to keep this fix narrow. Not exercised by this project's own
C<cli/poller.pl>, which always supplies both callbacks - this closes a
latent gap in C<run_once>'s
general-purpose API contract for any caller that legitimately omits one.

An C<edited_message> update (TGT-169, a live Telegram question from
Michael: "is the implementable if the user on telegram edit the
previous message and that will notify the agent about the updated
message") is detected and printed as its own event - Telegram's Bot
API sends this distinct update, the same shape as an ordinary
C<message> but reflecting the post-edit content, generally when a
message known to the bot in an allow-listed chat is edited (Telegram's
own docs note it can be omitted for edits to fields the bot never used,
so this is not an absolute guarantee for every possible edit). Gated
by the same C<is_allowed> check every other branch uses (by chat_id,
same as every other branch); no C<add_pending> - an edit isn't a
first-contact event, matching C<message_reaction>'s own precedent
above. Unlike a reaction, a text edit changes the message's actual
content, so (deliberately different from C<message_reaction>'s
detection-only behavior) its new text IS recorded via
C<record_message>, so C<d2 tg.history> reflects it - a caption/media-
only edit (no text) is still announced but deliberately NOT recorded,
to avoid overwriting an already-correct history summary with nothing
useful; recording those too is a narrower follow-up, out of this
ticket's own scope. Deletion of an ordinary chat message cannot be
detected at all - the Bot API has no update for that (a separate,
business-connection-scoped C<deleted_business_messages> update exists
for an unrelated feature this project doesn't use) - a hard platform
limitation with no client-side workaround, not a gap in this
implementation.

This module prints message content via an unqualified C<print> (Perl's
currently selected default output handle, ordinarily C<STDOUT>) and
reports errors via C<warn> (which always targets C<STDERR>); it does
nothing itself to give either an encoding layer (TGT-117, a live-experienced incident: an unadorned C<STDOUT>
warns "Wide character in print" on any non-Latin-1 message text, e.g. a
real Cantonese voice-note transcript - never fatal, the message is still
printed and delivered correctly, just noisy). Opening those streams with
an explicit C<:encoding(UTF-8)> layer is the calling entrypoint's
responsibility, not this module's - see C<cli/poller.pl>, which does
this at startup, before option handling and any poller work.

=head1 FUNCTIONS

=head2 open_store_or_die(%args)

TGT-186 (found via a scheduled JOB-003 hourly bug hunt, reproduced live
against C<cli/history.pl>): 7 C<cli/*.pl> scripts (C<attachment>,
C<text-only-replies>, C<approve>, C<retry-download>, C<history>,
C<reply>, C<unread>) each independently constructed
C<D2TG::Store-E<gt>new> unwrapped, sharing the identical raw-crash/
db-path-leak risk C<cli/poller.pl>'s own call already had before
TGT-183 fixed it. All 8 call sites (these 7 plus C<poller.pl>'s own)
built the same C<db_path> shape and the same overall
C<eval>/classify/refuse pattern - C<poller.pl> passes C<admin_chat_id>
as an arrayref of every configured group's chat_id, these 7 pass a
plain scalar, not byte-identical args - so this is a shared helper
(taking C<admin_chat_id> opaquely, whatever shape the caller passes)
rather than 7 separate C<eval>-wraps, matching this project's
established TGT-167/170/171/172/177 duplication-removal precedent.
Takes C<skill_root>, C<base_dir>, C<admin_chat_id> (the same
args C<D2TG::Config::state_db_path> and C<D2TG::Store-E<gt>new>
themselves need); on a storage-open failure, classifies the error via
C<_classify_store_error> and prints the same scrubbed
C<Failed to open local storage (REASON) - refusing to start.> refusal
TGT-183 established for C<cli/poller.pl>, then exits 1 - never returns
in that case. Returns the open store on success. C<cli/poller.pl>'s
own inline version is deliberately left untouched rather than
refactored to call this too - its TGT-185 lock-release logic is
intertwined with that specific call site, not required scope.

=head2 persist_offset_safe($store, $offset, $bot_key)

TGT-166 (found via a scheduled hourly bug-hunt, a direct follow-up
sweep after TGT-165 for the same unwrapped-DBI-call pattern):
C<cli/poller.pl>'s persistent main loop calls this instead of
C<$store-E<gt>set_offset(...)> directly. Unlike C<run_once>'s own
C<is_allowed>/C<add_pending> calls (TGT-165, both inside
C<run_once_safe>'s own C<eval>), the old direct call sat at the TOP
LEVEL of the persistent poller script's main loop - so a locked/busy
SQLite database used to crash the ENTIRE poller process outright, not
just one poll cycle's batch. Returns a true/false success flag
(TGT-191, changed from always-void): true and does nothing else if
C<$offset> is undef, matching the caller's own pre-existing "if defined"
guard - nothing to persist is not a failure. Otherwise C<eval>-wraps
C<set_offset>; on error, classifies it into a short fixed reason rather
than ever echoing the raw exception (TGT-133 precedent - a DBI/SQLite
error can embed the database file's own path), logs it to STDERR, and
returns false; on success, returns true.

C<cli/poller.pl>'s own main loop (TGT-191, a live production incident:
2 real messages permanently lost) only advances its in-memory offset
when this returns true - Telegram forgets/never redelivers an update
once a LATER offset has been sent to it, so advancing the in-memory
offset on a failed persist would let the next C<getUpdates> call
confirm a batch to Telegram that was never durably saved locally; if
the process then crashed before a later persist succeeded, that gap
was permanently unrecoverable. With the offset held back instead, a
later poll cycle retries persisting THIS SAME offset (not a newer
one), and the corresponding C<getUpdates> call is re-issued with the
same still-unconfirmed offset too, so Telegram redelivers the batch
rather than discarding it - deduplicated locally via C<record_message>'s
own upsert and C<run_once>'s own already-recorded check (TGT-178).
Extracted as a public function (rather than a private
C<_>-prefixed one like C<_record_message_safe> below) specifically so
it is directly unit-testable from outside this module, since the
caller (a persistent script requiring a live Telegram connection to
run its main loop at all) cannot practically be integration-tested.

=head2 skill_version_check_safe(%args)

TGT-175 (live production incident, reported via the budget project,
Michael's own owner chat): C<cli/poller.pl>'s main loop calls this
instead of C<D2TG::Config::skill_version(%args)> directly for its
per-cycle version-change check. A transient window where C<.env> is
briefly missing/unreadable during the skill's own self-update (an
install rewriting the directory mid-flight) used to be fatal to the
ENTIRE poller process, not just to that one check - matches
L</persist_offset_safe> above's own non-fatal-degradation pattern
(though unlike that function, this one logs the raw exception text
rather than classifying it first, since C<skill_version>'s own
failure messages never embed anything sensitive the way a raw
DBI/SQLite error can). C<eval>-wraps C<skill_version>; on error, logs
the message to STDERR (trailing newline stripped) and returns
C<undef> instead of dying, so the version-change check is simply
skipped for that cycle and re-checked on the next one. Returns the
version string unchanged on
success. Deliberately does NOT wrap the poller's own I<startup> call
to C<skill_version> (C<$starting_version>, read once before the poll
loop begins) - a fresh process launch with a genuinely missing or
misconfigured C<.env> should still refuse to start loudly, the same
"refuse to start" pattern C<D2TG_CHAT_ID>'s own hard guard already
uses; only this periodic re-check, made once the process is already
safely running, is the one that's safe to degrade instead of crash.

=head2 run_once_safe($telegram, $offset, $store, sleep => \&coderef, %run_once_opts)

Wraps C<run_once> so a transient failure (e.g. a network blip inside
C<get_updates>) never kills the caller's loop - see TGT-028, a real
production incident where an uncaught exception here silently ended the
whole poller process. On success, behaves exactly like calling
C<run_once> and taking its offset. On failure: if
L<D2TG::Config/is_transient_error> says the error looks transient (a
network timeout or a 5xx status), nothing is printed at all - the retry
loop below already recovers on its own, and printing it would only be
noise reaching the project's C<tira.policy.bridge> as a separate
C<monitor-output> event per occurrence (TGT-097, a live user request:
I<"instead of showing the polling error, just silent it ... and focus on
recovery instead">). Otherwise (a genuinely unexpected/non-transient
failure), strips the trailing newline from C<$@> and prints C<POLL
ERROR: <message>> to STDERR as before. Either way, sleeps 2 seconds (via
C<sleep>, injectable for tests; defaults to a real C<sleep>) to avoid
hammering a persistently-failing endpoint, and returns the I<unchanged>
C<$offset> so the next call retries from the same place. All other
C<%opts> (C<transcribe_voice>, C<download_media>) pass through to
C<run_once> unchanged.

=head2 run_once($telegram, $offset, $store, transcribe_voice => \&coderef, download_media => \&coderef, bot_token => $token)

Takes a L<D2TG::Telegram>-shaped object (anything with a C<get_updates>
method matching that signature), the current offset, and an optional
L<D2TG::Store>-shaped object (anything with C<is_allowed>/C<add_pending>
methods). When C<$store> is given, a sender not in its allow-list
(scoped by C<bot_token>, TGT-098 - the pair's own bot key, already
computed for multi-bot mode per TGT-049, now threaded into the store so
a chat_id approved under one bot never grants access under another) is
recorded via C<add_pending>, printing the one-time pending notification
described above but never the message text; when omitted, every
sender's text is printed unconditionally (used by earlier tests only -
C<cli/poller.pl> always passes a real store). Returns the raw updates array
and the next offset to pass on the following call.

Every C<$store-E<gt>record_message> call (edited text, plain text,
transcribed voice, downloaded media, and the no-callback fallback
branch - five call sites) goes through a private
C<_record_message_safe> wrapper (TGT-132),
matching L<D2TG::Store/record_failed_download>'s own established
eval-wrap pattern (TGT-104): a store write failure is logged non-fatally
to STDERR rather than propagating - the update was already printed and
handled, only its own record of that failed, and letting the exception
escape C<run_once> would make L</run_once_safe> return the offset
UNCHANGED, redelivering and reprinting the entire batch next cycle. The
raw exception text is never printed (a Codex review finding: a DBI/
SQLite error can embed the database file's own path) - only a short,
fixed classification (C<database is locked>/C<busy>/C<readonly>, or
C<an unexpected error>).

B<TGT-178> (Michael's own architectural ruling, answering the message-
loss investigation raised as TGT-176): C<_record_message_safe> now
returns a true/false success flag rather than void. C<run_once> tracks
the first update whose call failed, in the order the batch is
iterated (the same as the earliest, since Telegram delivers updates in
increasing C<update_id> order), and at the end of the batch caps the
returned offset at that failing update's own C<update_id>
instead of the batch's full next offset - Telegram never redelivers an
update once the offset has moved past it, so the old behavior (always
returning the batch's full offset) let a genuine store-write failure
permanently and silently lose that message's local history. Because
L<D2TG::Store/record_message> already upserts on its own
C<PRIMARY KEY (chat_id, message_id)>, a redelivered message's store
write is already idempotent with no schema change needed. To avoid
re-announcing a redelivered-but-already-recorded update (a duplicate
C<NEW TG>/re-download/re-transcription), C<run_once> checks
L<D2TG::Store/get_message> before acting on a plain message and skips
it entirely when a prior recording is found; a lookup failure is
treated as "not previously recorded" (proceed as normal), matching
this function's own established degrade-not-crash philosophy rather
than risking a silently dropped message over a possible rare duplicate
announcement.

An C<message_reaction> update (TGT-143, a live Telegram question -
"the user can give a like or mark a message with emoji") - Telegram's
own opt-in reaction-change type, requested via
L<D2TG::Telegram/get_updates>'s own C<allowed_updates> default - is
handled as its own branch, before any C<message> handling, and never
recorded into C<$store> (detection/printing only, per the ticket's own
scope; no reply action is taken on a reaction). Gated by the same
C<is_allowed> check the C<message> branch uses (TGT-151, found via a
scheduled bug hunt: this branch originally ran entirely before that
gate, so an unapproved, non-pending chat id's reaction was printed
unconditionally) - an unapproved chat id's reaction is silently
ignored, never queued via C<add_pending> since a reaction isn't a
first-contact event the way a message is. The sender name prefers
C<actor_chat.title>/C<.username> when C<actor_chat> is present (TGT-154,
found via a scheduled bug hunt: Telegram's own C<user> field is
optional - an anonymous chat/channel reaction omits it entirely and
supplies C<actor_chat> instead, so this branch previously fell through
to printing C<unknown> even though Telegram had supplied the channel's
real name; same failure class L</_forward_origin_name> already fixed
once for forwarded messages), falling back to the ordinary C<user>-based
L</_display_name> resolution otherwise. C<MessageReactionUpdated>
reports the I<full> current and previous reaction sets, not a single
before/after pair, since a user can have multiple reactions on one
message and a single update can add one reaction while removing
another - the two sets are diffed via C<_reaction_key> (a Codex review
finding: C<ReactionType> is a tagged union - a standard C<emoji>
reaction carries an emoji glyph, but C<custom_emoji> carries a distinct
C<custom_emoji_id> with no glyph at all, and C<paid> carries neither;
keying on the emoji field alone collapsed every custom/paid reaction
into one shared bucket, silently hiding a real swap between two
different custom emojis). Every key present in C<new_reaction> but not
C<old_reaction> prints C<NEW TG REACTION [chat_id] sender: <label> on
message <id>>, every key present in C<old_reaction> but not
C<new_reaction> prints C<REACTION REMOVED [chat_id] sender: <label> on
message <id>> - C<_reaction_label> prints the emoji glyph itself for a
standard reaction, or a plain description (C<a custom emoji>/C<a paid
reaction>) when there's no glyph to show; both are sanitized via
L</_sanitize_for_stdout> before printing, exactly like every other
untrusted string this module prints (a Telegram username/emoji is
attacker-controlled). Anonymous aggregate reaction counts
(C<message_reaction_count>) are out of scope.

Every printed sender name (the main content line and any reply-context
suffix) goes through L</_display_name> (TGT-079, a live user request):
a message from the L<D2TG::Config/chat_id> chat shows
L<D2TG::Config/owner_name> (C<D2TG_OWNER>) instead of the sender's raw
Telegram username, when that env var is set - purely a display
preference, with no effect on access control.

If the message carries Telegram's own C<forward_origin> field (TGT-142,
a live question answered by Michael: "use the origin name instead of
user id") - i.e. it was forwarded - the sender name additionally names
the I<original> author via a private C<_forward_origin_name> helper,
not just the immediate forwarder C<_display_name> already resolves:
C<"E<lt>original nameE<gt> (forwarded by E<lt>forwarderE<gt>)">. Both
this branch and L</_reply_context_suffix>'s own handling of a
replied-to forwarded message share this formatting via a private
C<_format_forwarded_sender> helper (TGT-170, found via a scheduled
improvement hunt - the two call sites had duplicated the same
four-line formatting logic, only the variable name differed - a pure
extraction with no behavior change).
C<MessageOriginUser> resolves to the original sender's username (their
first name as a fallback, never their bare numeric id); C<MessageOriginHiddenUser>
prints exactly the name string Telegram itself supplies (its own privacy
model withholds anything more from a bot - never claimed more certain
than that); C<MessageOriginChat>/C<MessageOriginChannel> name the
originating chat/channel rather than a person. An ordinary,
non-forwarded message is completely unaffected. The same handling
applies to L</_reply_context_suffix>'s own C<$original_sender> - a reply
to a forwarded message names its original author too, not just its
forwarder.

C<transcribe_voice>, if given, is called as
C<< $transcribe_voice->($telegram, $file_id) >> for a voice message and
should return its transcript text (typically wiring L<D2TG::Download>
and L<D2TG::Transcribe> together). Before that (potentially
multi-minute, blocking) call, a
C<NEW TG VOICE [chat_id] sender: transcribing... (this may take a few
minutes)> notice is printed immediately (TGT-100, a live user request:
the watching agent should notice a voice note arrived and can
acknowledge it right away, instead of the whole wait being silent until
the real transcript line appears). Its success then prints
C<NEW TG VOICE [chat_id] sender: <transcript>> to STDOUT; its failure
prints C<TRANSCRIBE ERROR [chat_id] sender: <message>> to STDERR and the
loop continues - one bad voice note never crashes the poller. Without
C<transcribe_voice>, a voice message falls back to the plain
C<NEW TG MEDIA> line (no pre-transcription notice, since there's no
blocking call to warn about).

C<download_media>, if given, is called as
C<< $download_media->($telegram, $file_id) >> for a photo or document
message and should return the local path it was downloaded to (typically
wrapping L<D2TG::Download>). For a photo, C<$file_id> is taken from the
I<last> entry of Telegram's C<photo> array (Telegram lists C<PhotoSize>
entries smallest-first, so the last is the largest); for a document, it
is C<< $message->{document}{file_id} >> directly. Success prints
C<NEW TG MEDIA [chat_id] sender: <type>> to STDOUT followed by a
C<GET ATTACHMENT WITH: d2 tg.attachment <chat_id> <message_id>> line
(TGT-133, via L</_print_attachment_template> - the real local path
returned by C<download_media> is never printed anywhere, only passed to
C<$store-E<gt>record_message>'s own C<local_path> argument); failure
prints C<MEDIA DOWNLOAD ERROR [chat_id] sender: <message>> to STDERR and
the loop continues, matching C<transcribe_voice>'s non-fatal handling.
Without C<download_media>, photo/document messages fall back to the
plain C<NEW TG MEDIA> line (no attachment to fetch, so no
C<GET ATTACHMENT WITH> line either).

A C<download_media> failure, when C<$store> is given, is also queued via
L<D2TG::Store/record_failed_download> (TGT-104, user-supplied
feature-gap analysis) - chat_id, message_id, file_id, sender, media
kind, caption, and the original error - so C<d2 tg.retry-download> can
retry it later using the same C<file_id> to request a fresh download,
which is genuinely useful for the transient failures (a network hiccup,
a momentary server error) this queue targets. That queue write is
itself wrapped in its own C<eval> and reported on STDERR if it fails (a
Codex review finding: a locked/full SQLite database must not turn an
already-non-fatal download error into a poll-cycle failure).

If the message carries a caption (TGT-092, a live production incident:
a caption was silently dropped entirely before this fix, causing a real
miscommunication - C<$message->{caption}> is a field the Bot API
attaches to photo/document messages, separate from C<$message->{text}>,
which is only present for plain text messages), it is sanitized the
same way inbound text already is (TGT-039) and appended to both the
printed C<NEW TG MEDIA> line (as C<- caption: <text>>) and the stored
message summary. A message with no caption - the common case - is
completely unaffected. This applies to both the C<download_media>
success path above and the plain fallback C<NEW TG MEDIA> line below.

Before calling C<download_media> at all, if the message's own declared
C<file_size> exceeds C<TELEGRAM_GETFILE_MAX_BYTES> (20MB, TGT-037 - a
live bug report: Telegram's Bot API C<getFile> endpoint has a hard,
documented 20MB limit and returns an opaque C<400 Bad Request> for
anything larger), C<download_media> is never called at all - a specific
C<MEDIA DOWNLOAD ERROR [chat_id] sender: file too large to download
(<N>MB, Telegram's Bot API getFile limit is 20MB)> is printed to STDERR
instead, so the operator can tell this apart from a genuine bug at a
glance. A message with no declared C<file_size> (Telegram does not
always send one) falls through to the normal download attempt
unaffected.

C<_sanitize_for_stdout> (TGT-039) is applied to inbound text I<and> a
successfully transcribed voice message before either is printed or
stored via C<record_message>: it escapes any C<\r>/C<\n> to a literal
C<\n> and strips other control characters, so a C<NEW TG>/C<NEW TG
VOICE> line - whose content may otherwise legitimately span multiple
lines, e.g. whisper's own per-segment output for a longer voice note -
is always exactly one stdout line, matching what every downstream
consumer (a Tira monitor job's feeder) requires.

C<_run_non_fatal> is the shared internal helper both of the above use:
it evals a callback, and on failure strips the trailing newline from
C<$@> and prints C<< <error_prefix> [chat_id] sender: <message> >> to
STDERR, returning C<(0, undef)>; on success it returns
C<(1, $result)>. The caller is responsible for printing its own
differently-shaped success line.

Every **stdout** event line (C<NEW TG>/C<NEW TG VOICE>/C<NEW TG
MEDIA>/C<NEW TG PENDING>) is prefixed with a C<[YYYY-MM-DD HH:MM:SS]>
timestamp (TGT-061, see C<_timestamp_prefix>), sourced from Telegram's
own C<message.date> field rather than local wall-clock time - it
reflects when Telegram itself received the message, not when this
poller happened to process it, which can lag behind by a poll cycle or
more. The C<TRANSCRIBE ERROR>/C<MEDIA DOWNLOAD ERROR> **stderr** lines
above are NOT timestamped (TGT-065) - C<_run_non_fatal> and the
oversized-file branch never receive or use C<$ts>.

Every content line also names the message's own C<message_id> as
C<< (msg #N) >> (TGT-040), when Telegram provided one.

Every content line (text, a successfully transcribed voice message, or a
successfully/plainly reported photo/document) is immediately followed by
a C<< REPLY WITH: d2 tg.reply <chat_id> "..." [--bot <token>] --reply-to-message-id <id> >>
line - a ready-to-run reply command template with the chat id and
message id filled in, per the owner's answered design question (Q-004).
The C<--reply-to-message-id> flag (TGT-040) is only included when
C<message_id> is known. C<--bot <masked_token>> (TGT-057) is only
included when C<bot_token> is given to C<run_once> - C<cli/poller.pl> passes
its own receiving bot's token here whenever it's running in multi-bot
mode (TGT-049), since C<d2 tg.reply>'s C<D2TG_TOKEN> fallback can't know
which of a pool of bots to use; single-bot/env-only mode never passes
C<bot_token>, so its template is unchanged. The token is masked (TGT-086,
via L<D2TG::Config/masked_token>, the same masking C<cli/poller.pl>'s own
startup line already uses, TGT-045) rather than printed in full - this
line reaches the target project's C<tira.policy.bridge> as a
C<monitor-output> event on a shared board, and the real token is a
credential, not something safe to broadcast there on every inbound
message. This means the printed C<--bot> value in multi-bot mode is not
directly runnable as-is; whoever runs C<d2 tg.reply> for that chat must
supply the real token themselves. Passing C<--reply-to-message-id>
through to C<d2 tg.reply> makes the resulting reply thread natively under
the original message in Telegram's
UI. This is only ever a template: nothing in this module ever calls
L<D2TG::Reply> or sends a reply itself. The pending-notification line and
the two C<*ERROR> lines never get one - there is nothing to reply to yet.

If Telegram's C<reply_to_message> field is present on the message (the
sender used Telegram's native reply-to-message feature), every content
line above also gets a C<< (replying to <sender> [msg #N]: <snippet-or-
kind>) >> suffix (TGT-029, message id added TGT-041), naming who/what
the reply targets: the original sender's username, that message's own
C<message_id> (omitted, along with its brackets, only if Telegram's
payload didn't carry one), and a description of the original message. A
message with no C<reply_to_message> gets no suffix at all. See
C<_reply_context_suffix>.

As of TGT-038, that description is looked up first in C<$store> (via
C<get_message>, keyed on the original message's own C<chat_id>+
C<message_id>) - this is richer than Telegram's own payload for media/
voice, since it can be the downloaded file's C<local_path> or the actual
transcript rather than just the bare word C<photo>/C<document>/C<voice>.
Every successfully processed content line (text, transcribed voice, or
downloaded photo/document) is itself recorded into C<$store> via
C<record_message> immediately after being printed, so a later reply to it
can be looked up this way. Only when nothing is stored (a reply to a
message from before this feature existed, from a sender never allow-
listed at the time, or when C<$store> is not given at all) does the
suffix fall back to the original Telegram-payload-only behavior: a
sanitized/truncated (5000 chars, TGT-035) snippet of the original text,
or its media kind if the original had none.

=cut
