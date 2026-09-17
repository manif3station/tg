package D2TG::Poller;

use strict;
use warnings;
use POSIX qw(strftime);
use D2TG::Poller::Format;
use D2TG::Poller::Safe;

use constant TELEGRAM_GETFILE_MAX_BYTES => 20 * 1024 * 1024;

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
                # TGT-198: promoted to the shared store_write_safe
                # helper - see its own comment for why is_allowed/
                # add_pending need the (\$ok, \$value) return shape.
                my ( $ok, $allowed ) =
                  D2TG::Poller::Safe::store_write_safe( $chat_id, 'is_allowed', sub { $store->is_allowed( $chat_id, $bot_token ) } );
                next unless $ok;
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
                # TGT-198: promoted to the shared store_write_safe
                # helper - see its own comment for why is_allowed/
                # add_pending need the (\$ok, \$value) return shape.
                my ( $ok, $allowed ) =
                  D2TG::Poller::Safe::store_write_safe( $chat_id, 'is_allowed', sub { $store->is_allowed( $chat_id, $bot_token ) } );
                next unless $ok;
                next unless $allowed;
            }

            my $sender      = _display_name( $chat_id, $edited->{from}{username} );
            my $message_id  = $edited->{message_id};
            my $edited_text = $edited->{text};
            my $has_text    = defined $edited_text && length $edited_text;
            my $safe_text   = $has_text ? _sanitize_for_stdout($edited_text) : '(no text)';
            my $ts = _timestamp_prefix($edited);

            # TGT-273 (found via a scheduled JOB-004 improvement hunt):
            # unlike the plain-message/media/voice branch (TGT-178/
            # TGT-270), this branch had no redelivery-dedup guard at
            # all - a Telegram redelivery of the same edited_message
            # update (its own documented at-least-once delivery)
            # re-printed a duplicate NEW TG EDIT line every time.
            # Reusing get_message the way TGT-270 did does NOT work
            # here unmodified: record_message UPSERTs on (chat_id,
            # bot_key, message_id), so get_message returns non-null for
            # ANY message ever recorded, including the ORIGINAL
            # pre-edit send - presence alone would wrongly suppress a
            # genuinely new edit too. Comparing the incoming text
            # against the already-stored summary distinguishes the two:
            # identical means this exact edit was already recorded (a
            # redelivery); different (or no stored row at all) means a
            # genuinely new edit, or the very first one. Only applies
            # when $has_text is true - a caption/media-only edit is
            # never recorded via record_message at all (see below), so
            # there is no stored state to compare against for that
            # case; a transient lookup error degrades the same way
            # every other dedup check in this file already does
            # (treated as not-previously-seen, proceed as normal).
            if ( $store && $has_text ) {
                my $already_announced = eval { $store->get_message( $chat_id, $message_id, bot_key => $bot_token ) };
                next if !$@ && $already_announced && $already_announced->{summary} eq $safe_text;
            }

            print "$ts NEW TG EDIT [$chat_id] $sender: $safe_text (msg #$message_id, edited)\n";

            # TGT-217 (found via a scheduled JOB-003 hourly bug hunt):
            # every other actionable branch (message/media/voice/
            # document/photo) calls _print_reply_template right after
            # its own NEW TG ... line - this branch was the sole
            # actionable one missing it, leaving an edited message
            # announced with no ready-to-run reply command, unlike
            # every other event type. Printed for both the text-edit
            # and caption/media-only-edit cases - only the store
            # recording below is conditional on having real text, not
            # this announcement.
            _print_reply_template( $chat_id, $message_id, $bot_token );

            # Codex review finding: a caption/media-only edit (no
            # $edited->{text} at all - a text edit is the only kind
            # this narrow ticket handles) would otherwise overwrite an
            # already-correct history summary with the literal string
            # '(no text)', corrupting it. Only record when there is
            # real text to record; the edit is still announced either
            # way, just not (yet) reflected in d2 tg.history when it's
            # a caption/media change.
            if ( $store && defined $message_id && $has_text ) {
                D2TG::Poller::Safe::record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, $safe_text, bot_key => $bot_token );
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
            # TGT-198: promoted to the shared store_write_safe helper -
            # see its own comment for why is_allowed/add_pending need
            # the (\$ok, \$value) return shape.
            my ( $ok, $allowed ) =
              D2TG::Poller::Safe::store_write_safe( $chat_id, 'is_allowed', sub { $store->is_allowed( $chat_id, $bot_token ) } );
            next unless $ok;

            unless ($allowed) {
                my ( $add_ok, $added ) =
                  D2TG::Poller::Safe::store_write_safe( $chat_id, 'add_pending', sub { $store->add_pending( $chat_id, $bot_token ) } );
                next unless $add_ok;
                if ($added) {
                    print "$ts NEW TG PENDING [$chat_id] awaiting approval\n";
                }
                next;
            }
        }

        my $reply_ctx  = _reply_context_suffix( $message, $store, $chat_id, $bot_token );
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
            my $already_recorded = eval { $store->get_message( $chat_id, $message_id, bot_key => $bot_token ) };
            next if !$@ && $already_recorded;

            # TGT-270 (a live report from Michael via the budget
            # project): the check above alone missed a real case of the
            # exact same redelivery problem it exists to solve - a
            # media/voice message whose download or transcription
            # already failed and was queued is NEVER recorded via
            # record_message (only record_failed_download/
            # record_failed_transcription, different tables), so a
            # Telegram redelivery of that update_id (its own documented
            # at-least-once delivery) was invisible to this guard and
            # got legitimately re-processed as brand new - re-printing
            # a MEDIA DOWNLOAD ERROR/re-attempting a download that read
            # exactly like a fresh live failure, when it was actually
            # the same already-queued one from days earlier. Same
            # transient-error degradation as the check above: treated
            # as "not previously queued" on lookup failure, proceed as
            # normal.
            my $already_queued = eval {
                $store->has_failed_download( $chat_id, $message_id, bot_key => $bot_token )
                  || $store->has_failed_transcription( $chat_id, $message_id, bot_key => $bot_token );
            };
            next if !$@ && $already_queued;
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
                D2TG::Poller::Safe::record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, $safe_text, bot_key => $bot_token );
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
                    D2TG::Poller::Safe::record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, $safe_transcript, bot_key => $bot_token );
                }
            }
            elsif ( $store && defined $message_id && defined $file_id ) {

                # TGT-237 (found via a scheduled JOB-003 hourly bug
                # hunt): a failed transcription used to be reported once
                # (TRANSCRIBE ERROR, STDERR only) and permanently lost -
                # no queue, no retry, unlike failed_downloads (TGT-104).
                # Mirrors that established queue-write pattern exactly,
                # including its own non-fatal eval-wrap (a locked/full
                # SQLite database must not turn an already-non-fatal
                # transcription error into a poll-cycle failure).
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
                    # TGT-204's own stdout-visibility precedent: the
                    # TRANSCRIBE ERROR line above goes to STDERR only,
                    # which never reaches the monitor job's stdout-fed
                    # tira.policy.bridge stream - printed only when the
                    # queue write itself succeeded, naming the exact
                    # recovery command, matching NEW TG MEDIA FAILED.
                    print "$ts NEW TG VOICE FAILED [$chat_id] $sender: "
                      . "transcription failed - queued for retry, "
                      . "RETRY WITH: d2 tg.retry-transcription --all" . _bot_flag($bot_token) . "\n";
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
                        D2TG::Poller::Safe::record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note", local_path => $local_path, bot_key => $bot_token );
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

                            # TGT-219 (found via a scheduled JOB-004
                            # improvement hunt): $bot_token was already
                            # in scope here (used above for is_allowed/
                            # _print_reply_template) but never threaded
                            # through - Telegram's own file_id values
                            # are bot-token-scoped, so a multi-bot
                            # config's retry would silently use the
                            # wrong bot without this.
                            bot_key => $bot_token,
                        );
                    };
                    if ($@) {
                        my $queue_error = $@;
                        $queue_error =~ s/\n\z//;
                        print STDERR "MEDIA DOWNLOAD ERROR [$chat_id] $sender: "
                          . "failed to queue for retry too: $queue_error\n";
                    }
                    else {
                        # TGT-204 (a real, live-reported visibility
                        # gap): the MEDIA DOWNLOAD ERROR line above
                        # goes to STDERR only, which never reaches the
                        # monitor job's own stdout-fed tira.policy.bridge
                        # notification stream - a queued failed
                        # download was otherwise invisible until a
                        # human/agent thought to read the poller's own
                        # raw output directly or ran
                        # `d2 tg.retry-download --all` speculatively.
                        # Printed only when the queue write itself
                        # succeeded (the "else" above already reports a
                        # failure to queue), matching NEW TG MEDIA's
                        # own STDOUT visibility and naming the exact
                        # recovery command, same convention as
                        # _print_attachment_template's own
                        # GET ATTACHMENT WITH line.
                        # TGT-220 (found via a scheduled JOB-003 hourly
                        # bug hunt): $bot_token is already in scope
                        # here (used above for is_allowed and threaded
                        # into record_failed_download's own bot_key
                        # arg two lines earlier, per TGT-219) - a
                        # multi-bot config's retry command must be
                        # scoped the same way _print_reply_template's
                        # own masked --bot flag already is, or
                        # following this line literally retries
                        # nothing (cli/retry-download.pl --all with no
                        # --bot only acts on the default-bot sentinel
                        # queue).
                        print "$ts NEW TG MEDIA FAILED [$chat_id] $sender: "
                          . "$media_kind$caption_note - queued for retry, "
                          . "RETRY WITH: d2 tg.retry-download --all" . _bot_flag($bot_token) . "\n";
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
                D2TG::Poller::Safe::record_message_and_track_offset( $store, \$offset_cap, $update_id, $chat_id, $message_id, $sender, "$media_kind$caption_note", bot_key => $bot_token );
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

# TGT-259: this 13-sub stdout-formatting cluster moved into
# D2TG::Poller::Format (built as plain functions there, sharing no
# poller state). 11 of the 13 keep a thin forwarder here so every
# remaining caller (internal Poller.pm call sites, plus the one
# confirmed external caller - t/226-bot-flag-helper-extracted.t calls
# _bot_flag directly) keeps working unchanged. _stored_summary and
# _forward_origin_name got none: their only caller was
# _reply_context_suffix/_format_forwarded_sender respectively, both
# themselves part of this cluster and now calling Format's own bare
# functions directly - matching Tira's own 5.133 precedent ("the other
# three helpers have no caller outside police_world itself and get
# none"). See D2TG::Poller::Format's own POD for the full behavior
# each one documents.
sub _display_name             { return D2TG::Poller::Format::display_name(@_) }
sub _reply_context_suffix     { return D2TG::Poller::Format::reply_context_suffix(@_) }
sub _timestamp_prefix         { return D2TG::Poller::Format::timestamp_prefix(@_) }
sub _sanitize_for_stdout      { return D2TG::Poller::Format::sanitize_for_stdout(@_) }
sub _bot_flag                 { return D2TG::Poller::Format::bot_flag(@_) }
sub _print_reply_template     { return D2TG::Poller::Format::print_reply_template(@_) }
sub _print_attachment_template { return D2TG::Poller::Format::print_attachment_template(@_) }
sub _reaction_key              { return D2TG::Poller::Format::reaction_key(@_) }
sub _reaction_label            { return D2TG::Poller::Format::reaction_label(@_) }
sub _format_forwarded_sender   { return D2TG::Poller::Format::format_forwarded_sender(@_) }
sub _media_kind                { return D2TG::Poller::Format::media_kind(@_) }

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

