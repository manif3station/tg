package D2TG::Reply;

use strict;
use warnings;
use D2TG::TTS;
use D2TG::Config;
use D2TG::Poller;

# TGT-192 (found via a scheduled JOB-003 hourly bug hunt, the same
# class of issue TGT-191 just fixed - an external system told "done"
# before the corresponding local write is safely handled): every
# other D2TG::Store write call site in this codebase already wraps its
# call in eval and classifies a failure via
# D2TG::Poller::_classify_store_error (record_message via
# _record_message_safe TGT-132, set_offset via persist_offset_safe
# TGT-166/191, is_allowed/add_pending TGT-165, record_failed_download's
# own eval TGT-104) - send_reply/resend_voice's own record_sent_text/
# record_sent_voice/mark_read calls were the one exception. A locked/
# busy database there died raw (potentially leaking the real db_path)
# AFTER send_message had already succeeded, aborting the rest of
# send_reply (skipping voice synthesis entirely) and reporting a hard
# failure that could even suggest retrying - risking a duplicate text
# delivery, since TGT-114's own dedup check depends on the very row
# that failed to write. Shared here so all 5 call sites use identical
# wrapping/classification/message shape.
sub _store_write_safe {
    my ( $chat_id, $description, $code ) = @_;
    eval { $code->() };
    if ($@) {
        my $reason = D2TG::Poller::_classify_store_error($@);
        print STDERR "STORE ERROR [$chat_id]: $description failed - $reason\n";
    }
    return;
}

sub send_reply {
    my (%args) = @_;

    my $telegram = $args{telegram} or die "D2TG::Reply::send_reply requires telegram\n";
    my $chat_id  = $args{chat_id};
    my $text     = $args{text};
    my $synth    = $args{synthesize} || \&D2TG::TTS::synthesize;

    my %opts = defined $args{reply_to_message_id}
      ? ( reply_to_message_id => $args{reply_to_message_id} )
      : ();

    # TGT-114: refuse a send whose exact text already went out to this
    # same chat/bot within a short window - a retried send_reply call
    # after a transient failure, or an agent accidentally re-running the
    # same d2 tg.reply command, previously had no way to avoid delivering
    # the identical message twice. Only checked when a store is given -
    # unchanged behavior for a caller that never opts into this feature.
    if ( $args{store} && $args{store}->is_recent_duplicate_reply( $chat_id, $text, bot_key => $args{bot_key} ) ) {
        die "D2TG::Reply::send_reply: refusing to send - this exact text was already sent to "
          . "chat_id $chat_id moments ago (duplicate within the dedup window)\n";
    }

    my $text_result = $telegram->send_message( $chat_id, $text, undef, %opts );

    # TGT-105: record the text send BEFORE synthesis/send_voice can
    # fail - a row with no matching voice_message_id yet IS the
    # after-the-fact text-only audit trail this ticket exists to
    # provide, for exactly the case TGT-083's own tradeoff describes:
    # a synthesis/send_voice failure here is reported loudly (the die
    # below), but if that's missed, this row is what a later checker
    # catches it with. Uses the LAST chunk's message_id when a long
    # reply auto-split into multiple messages (TGT-013's own
    # split_text_utf16) - the single-chunk case (by far the common one)
    # is unaffected. Only attempted when a store is actually given -
    # $telegram is only contractually required to respond to
    # send_message/send_voice (existing callers/tests use bare fakes
    # returning any shape they like when they don't care about this
    # feature), so this must never assume $text_result's own shape
    # unless a caller has opted in by passing store.
    my $text_message_id;
    if ( $args{store} ) {
        $text_message_id = eval { $text_result->[-1]{message_id} };
        _store_write_safe( $chat_id, 'record_sent_text', sub {
            $args{store}->record_sent_text( $chat_id, $text_message_id, bot_key => $args{bot_key}, text => $text );
        } ) if defined $text_message_id;
    }

    my $voice_result = _synthesize_and_send_voice(
        telegram   => $telegram,
        chat_id    => $chat_id,
        text       => $text,
        synthesize => $synth,
        tts_args   => $args{tts_args},
        opts       => \%opts,
    );

    # A Codex QA-stage review finding (round 2): $voice_result->{message_id}
    # must be extracted BEFORE _store_write_safe's own eval, not
    # inside its closure - otherwise a malformed $voice_result (not a
    # hashref) dereferenced there could be misclassified as a
    # "record_sent_voice failed" STORE ERROR and swallowed non-fatally.
    #
    # Round 3 (same review, next pass): an eval-guarded dereference is
    # not actually sufficient here - C<undef->{key}> is a well-known
    # Perl non-death: reading a hash key off undef in rvalue context
    # quietly returns undef, it does not raise an exception for eval
    # to catch (verified directly: C<eval { undef()->{k} }> leaves C<$@>
    # empty). So a bare C<eval { $voice_result->{message_id} }> can
    # never distinguish "malformed result" from "well-formed hashref
    # legitimately missing this key" (e.g. Fake::ReplyTelegram's own
    # 'shapeless' option, C<{ ok => 1 }>) - both silently yield undef.
    # Checking C<ref($voice_result) eq 'HASH'> explicitly is the only
    # way to actually tell them apart. A non-hashref result (undef, a
    # plain string, etc.) now dies for real - matching what a
    # malformed shape deserves per TGT-083's own "voice failures are
    # loud, never silent" tradeoff - while a present-but-incomplete
    # hashref still quietly skips just the store write, same as
    # always.
    #
    # Round 6: this check must run whenever ANY store-dependent
    # behavior below depends on the voice result being trustworthy -
    # not only when $text_message_id happens to be defined too. mark_read
    # (below) is gated on store+reply_to_message_id alone, a strictly
    # broader condition than store+text_message_id; gating this check
    # on the narrower condition let a malformed result bypass it
    # entirely (and still get marked read) whenever a caller gave
    # store and reply_to_message_id but not text_message_id. Checked
    # whenever store is given at all - the broadest condition under
    # which anything below reads this result - so a caller that never
    # passes store remains entirely unaffected by this check, exactly
    # as before.
    if ( $args{store} ) {
        die "D2TG::Reply::send_reply: send_voice returned an unexpected result "
          . "(not a hashref) - cannot confirm the voice reply was actually sent\n"
          unless ref($voice_result) eq 'HASH';
    }

    my $voice_message_id;
    if ( $args{store} && defined $text_message_id ) {
        $voice_message_id = $voice_result->{message_id};
        _store_write_safe( $chat_id, 'record_sent_voice', sub {
            $args{store}->record_sent_voice( $chat_id, $text_message_id, $voice_message_id, bot_key => $args{bot_key} );
        } ) if defined $voice_message_id;
    }

    _store_write_safe( $chat_id, 'mark_read', sub {
        $args{store}->mark_read( $chat_id, $args{reply_to_message_id}, bot_key => $args{bot_key} );
    } ) if $args{store} && defined $args{reply_to_message_id};

    return { text => $text_result, voice => $voice_result };
}

sub resend_voice {
    my (%args) = @_;

    my $telegram = $args{telegram} or die "D2TG::Reply::resend_voice requires telegram\n";
    my $chat_id  = $args{chat_id};
    my $text     = $args{text};
    my $synth    = $args{synthesize} || \&D2TG::TTS::synthesize;
    my $text_message_id = $args{text_message_id};

    my %opts = defined $args{reply_to_message_id}
      ? ( reply_to_message_id => $args{reply_to_message_id} )
      : ();

    my $voice_result = _synthesize_and_send_voice(
        telegram   => $telegram,
        chat_id    => $chat_id,
        text       => $text,
        synthesize => $synth,
        tts_args   => $args{tts_args},
        opts       => \%opts,
    );

    # TGT-105: this is exactly what clears a send_reply-recorded
    # text-only flag once the missing voice half is actually recovered.
    # A Codex QA-stage review finding (same as send_reply's own, see
    # its comment above, rounds 2 and 3): C<ref($voice_result) eq
    # 'HASH'> is checked explicitly - C<eval { undef->{key} }> does not
    # raise an exception in Perl (it quietly returns undef), so an
    # eval-guarded dereference alone can never distinguish a malformed
    # (non-hashref) result from a well-formed hashref that's simply
    # missing this key. A non-hashref result now dies for real; a
    # present hashref missing the key (e.g. Fake::ReplyTelegram's
    # 'shapeless' option) still quietly skips just the store write.
    #
    # A round-5 Codex finding: this check - and the die it can raise -
    # must run BEFORE mark_read, not after. The original ordering ran
    # mark_read first, so a malformed voice result died AFTER the
    # message had already been marked read - defeating the exact
    # retry/recovery state this whole function exists to preserve on a
    # genuine failure. mark_read (below) now only runs after this
    # check.
    #
    # Round 6: this check must run whenever mark_read is even reachable
    # below, not only when $text_message_id happens to be defined too -
    # gating it on the narrower store+text_message_id condition (mark_read
    # is gated on the strictly broader store+reply_to_message_id) let a
    # malformed result bypass this check entirely, and still get marked
    # read, whenever a caller gave store and reply_to_message_id but not
    # text_message_id. Checked whenever store is given at all, so a
    # caller that never passes store remains entirely unaffected.
    if ( $args{store} ) {
        die "D2TG::Reply::resend_voice: send_voice returned an unexpected result "
          . "(not a hashref) - cannot confirm the voice reply was actually sent\n"
          unless ref($voice_result) eq 'HASH';
    }

    my $voice_message_id;
    if ( $args{store} && defined $text_message_id ) {
        $voice_message_id = $voice_result->{message_id};
        _store_write_safe( $chat_id, 'record_sent_voice', sub {
            $args{store}->record_sent_voice( $chat_id, $text_message_id, $voice_message_id, bot_key => $args{bot_key} );
        } ) if defined $voice_message_id;
    }

    # Codex review finding: without this, a successfully-recovered
    # reply (text already sent earlier, voice now resent here) stayed
    # unread forever - inviting later reprocessing/a duplicate full
    # reply, since nothing else ever marks it read for this recovery
    # path. Same guard as send_reply's own: only when both store and
    # reply_to_message_id are given, and only after send_voice has
    # actually succeeded (the round-5 finding above is exactly why this
    # now runs after, not before, the result-shape check).
    _store_write_safe( $chat_id, 'mark_read', sub {
        $args{store}->mark_read( $chat_id, $args{reply_to_message_id}, bot_key => $args{bot_key} );
    } ) if $args{store} && defined $args{reply_to_message_id};

    return { voice => $voice_result };
}

# TGT-158 (found via a scheduled improvement hunt): send_reply and
# resend_voice each independently implemented this exact synthesize/
# send/cleanup sequence - verified via direct read as genuine
# duplication, not merely structural similarity. Extracted here
# unchanged; each caller's own distinct surrounding logic (in
# particular the record_sent_voice/mark_read ordering, which the two
# callers genuinely differ on) is deliberately left in each caller,
# not folded into this helper, so this extraction cannot silently
# reorder either caller's own post-success side effects.
sub _synthesize_and_send_voice {
    my (%args) = @_;

    my $voice_path = $args{synthesize}->( $args{text}, %{ $args{tts_args} || {} } );

    my $voice_result = eval { $args{telegram}->send_voice( $args{chat_id}, $voice_path, %{ $args{opts} || {} } ) };
    my $send_voice_error = $@;
    unlink $voice_path if -e $voice_path;
    die $send_voice_error if $send_voice_error;

    return $voice_result;
}

sub format_send_error {
    my ($error) = @_;

    return $error
      . "This looks like a transient network error - try running the same d2 tg.reply command again.\n"
      if D2TG::Config::is_transient_error($error);

    return $error;
}

1;
