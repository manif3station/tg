use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Reply;
require Fake::ReplyTelegram;

# TGT-192 (found via a scheduled JOB-003 hourly bug hunt, the same
# class of issue TGT-191 just fixed): send_reply/resend_voice's own
# record_sent_text/record_sent_voice/mark_read calls used to be the
# one D2TG::Store write call shape in this codebase left unwrapped -
# a locked/busy database there died raw, AFTER send_message had
# already succeeded, aborting the rest of send_reply entirely
# (skipping voice synthesis, and reporting the whole call as a hard
# failure even though the text genuinely went out).

sub capture_stderr {
    my ($code) = @_;
    my $err = '';
    open my $fh, '>', \$err or die $!;
    local *STDERR = $fh;
    my @result = $code->();
    close $fh;
    return ( $err, @result );
}

package Fake::Store::DyingWrite;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        dies_on => $args{dies_on} || {},
        calls   => [],
    }, $class;
}

sub record_sent_text {
    my ( $self, @rest ) = @_;
    push @{ $self->{calls} }, [ 'record_sent_text', @rest ];
    die "database is locked\n" if $self->{dies_on}{record_sent_text};
    return;
}

sub record_sent_voice {
    my ( $self, @rest ) = @_;
    push @{ $self->{calls} }, [ 'record_sent_voice', @rest ];
    die "database is locked\n" if $self->{dies_on}{record_sent_voice};
    return;
}

sub mark_read {
    my ( $self, @rest ) = @_;
    push @{ $self->{calls} }, [ 'mark_read', @rest ];
    die "database is locked\n" if $self->{dies_on}{mark_read};
    return;
}

sub is_recent_duplicate_reply { return 0; }

package Fake::Telegram::MalformedVoiceResult;

sub new { return bless { sent_messages => [] }, shift; }

sub send_message {
    my ( $self, $chat_id, $text ) = @_;
    push @{ $self->{sent_messages} }, { chat_id => $chat_id, text => $text };
    return [ { message_id => 1 } ];
}

# Returns undef instead of the usual { message_id => ... } hashref -
# a malformed shape distinct from Fake::ReplyTelegram's own
# 'shapeless' option (which still returns a real hashref, { ok => 1 }).
sub send_voice { return undef; }

package main;

{
    # The failure scenario the ticket exists for: record_sent_text
    # dies (a locked database) immediately after send_message has
    # already succeeded.
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new( dies_on => { record_sent_text => 1 } );

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::send_reply(
            telegram   => $telegram,
            chat_id    => 999,
            text       => 'hello',
            store      => $store,
            synthesize => sub { return '/tmp/fake-voice.ogg' },
        );
    } );

    is( $err, "STORE ERROR [999]: record_sent_text failed - database is locked\n",
        'a record_sent_text failure is logged non-fatally with the exact classified reason text (D2TG::Poller::_classify_store_error\'s own fixed output, not arbitrary raw error text)' );
    unlike( $err, qr/at \S+\.pm line \d+/, 'the raw exception is never echoed as an uncaught Perl trace - only the classified reason (TGT-133 precedent)' );
    ok( defined $result, 'send_reply does not die - it returns normally despite the store write failure' );
    ok( $result->{text},  'the return value still reports the text send (send_message genuinely succeeded)' );
    ok( $result->{voice}, 'voice synthesis/send is STILL attempted after a record_sent_text failure - not skipped' );
    is_deeply( [ grep { $_ eq 'send_voice' } @{ $telegram->{call_order} } ], ['send_voice'],
        'send_voice was genuinely called, confirming voice was not silently skipped' );
}

{
    # record_sent_voice failing must not un-do the fact that both
    # sends already succeeded, and must not prevent mark_read from
    # still being attempted.
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new( dies_on => { record_sent_voice => 1 } );

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::send_reply(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
        );
    } );

    like( $err, qr/STORE ERROR \[999\]: record_sent_voice failed/, 'a record_sent_voice failure is logged non-fatally, classified' );
    ok( defined $result, 'send_reply does not die on a record_sent_voice failure either' );
    ok( ( grep { $_->[0] eq 'mark_read' } @{ $store->{calls} } ), 'mark_read is still attempted even after record_sent_voice failed' );
}

{
    # mark_read failing must not affect the reported result at all -
    # both sends already succeeded regardless of this local audit-trail
    # write's own outcome.
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new( dies_on => { mark_read => 1 } );

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::send_reply(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
        );
    } );

    like( $err, qr/STORE ERROR \[999\]: mark_read failed/, 'a mark_read failure is logged non-fatally, classified' );
    ok( defined $result && $result->{text} && $result->{voice}, 'send_reply still reports full success - a local audit-trail failure is never conflated with a real send failure' );
}

{
    # Regression: the fully-successful path is completely unaffected -
    # no STDERR output at all, all 3 store calls made exactly once.
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new;

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::send_reply(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
        );
    } );

    is( $err, '', 'nothing is printed to STDERR when every store write succeeds' );
    is( scalar @{ $store->{calls} }, 3, 'record_sent_text, record_sent_voice, and mark_read are each called exactly once' );
}

# TGT-192 (a Codex QA-stage review finding): the blocks above only
# exercise send_reply's own 3 call sites - resend_voice's own
# mark_read/record_sent_voice calls (2 of the 5 sites this fix
# touches) had no coverage at all. resend_voice never calls
# send_message, so its own return shape is just { voice => ... } -
# these blocks confirm both of its store writes are independently
# non-fatal too, matching send_reply's own guarantee.
{
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new( dies_on => { mark_read => 1 } );

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::resend_voice(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
            text_message_id      => 501,
        );
    } );

    is( $err, "STORE ERROR [999]: mark_read failed - database is locked\n",
        'resend_voice: a mark_read failure is logged non-fatally with the exact classified reason text' );
    ok( defined $result && $result->{voice}, 'resend_voice does not die on a mark_read failure - it still returns the voice result' );
    ok( ( grep { $_->[0] eq 'record_sent_voice' } @{ $store->{calls} } ), 'record_sent_voice is still attempted even after mark_read failed' );
}

{
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new( dies_on => { record_sent_voice => 1 } );

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::resend_voice(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
            text_message_id      => 501,
        );
    } );

    is( $err, "STORE ERROR [999]: record_sent_voice failed - database is locked\n",
        'resend_voice: a record_sent_voice failure is logged non-fatally with the exact classified reason text' );
    ok( defined $result && $result->{voice}, 'resend_voice does not die on a record_sent_voice failure either' );
}

{
    # Regression: resend_voice's own fully-successful path is
    # completely unaffected too.
    my $telegram = Fake::ReplyTelegram->new;
    my $store    = Fake::Store::DyingWrite->new;

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::resend_voice(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
            text_message_id      => 501,
        );
    } );

    is( $err, '', 'resend_voice: nothing is printed to STDERR when every store write succeeds' );
    is( scalar @{ $store->{calls} }, 2, 'resend_voice: mark_read and record_sent_voice are each called exactly once' );
}

# TGT-192 (a second Codex QA-stage review finding, on THIS ticket's
# own fix, rounds 2 and 3): _store_write_safe's eval must only cover
# the store write itself, not the evaluation of arguments passed to
# it. Round 2: an earlier draft evaluated $voice_result->{message_id}
# INSIDE the _store_write_safe closure, so a malformed (non-hashref)
# $voice_result's own dereference died inside that same eval,
# misclassified as a non-fatal "record_sent_voice failed" STORE ERROR,
# and swallowed. Round 3: the next draft moved the dereference outside
# _store_write_safe but then simply skipped the store write when it
# died - which converted the malformed result into a silently-reported
# SUCCESS instead, when this is exactly the class of voice-half
# failure that must propagate loudly (TGT-083's own tradeoff; this is
# also the pre-TGT-192 behavior - the raw dereference used to die
# uncaught here, reaching cli/reply.pl's own eval as a real reported
# failure). The fix now re-raises this as a die (only when a store
# write was actually going to be attempted, matching the original
# code's own gating), so a malformed send_voice result is neither
# misclassified as a store failure NOR silently treated as success -
# it is a real, reported failure, same as before this ticket ever
# existed.
{
    my $telegram = Fake::Telegram::MalformedVoiceResult->new;
    my $store    = Fake::Store::DyingWrite->new;

    my ( $err, $result ) = capture_stderr( sub {
        return eval {
            D2TG::Reply::send_reply(
                telegram             => $telegram,
                chat_id              => 999,
                text                 => 'hello',
                store                => $store,
                synthesize           => sub { return '/tmp/fake-voice.ogg' },
                reply_to_message_id  => 42,
            );
        };
    } );

    my $eval_error = $@;
    ok( !defined $result, 'send_reply dies (returns nothing) on a malformed send_voice result - it is not silently reported as success' );
    like( $eval_error, qr/unexpected result/, 'the die names the actual problem - an unexpected (non-hashref) send_voice result' );
    unlike( $err, qr/STORE ERROR/, 'this failure is never misreported as a STORE ERROR - it is not a store-write problem at all' );
    is_deeply( [ grep { $_->[0] eq 'record_sent_voice' } @{ $store->{calls} } ], [],
        'record_sent_voice is never attempted at all when send_voice returned a malformed (non-hashref) result' );
    # A Codex QA-stage review finding (round 4): this state - text
    # already sent, voice result malformed - must leave the message
    # genuinely unread, so a later retry/recovery path (resend_voice,
    # or a human noticing) still finds it pending. mark_read is only
    # ever reached after this block's own die already unwound the
    # call, so it must never have run.
    is_deeply( [ grep { $_->[0] eq 'mark_read' } @{ $store->{calls} } ], [],
        'mark_read is never attempted either - the message is correctly left unread after a malformed voice result, not falsely marked handled' );
}

{
    # Regression: Fake::ReplyTelegram's own pre-existing 'shapeless'
    # option (a REAL hashref, { ok => 1 }, just missing the message_id
    # key) must still be treated as a legitimate shape that quietly
    # skips the store write - not the malformed (non-hashref) case
    # above. This is the case t/84-text-only-reply-audit.t already
    # exercises for send_reply's overall return value; this block
    # confirms it specifically does not die and does not log a STORE
    # ERROR either.
    my $telegram = Fake::ReplyTelegram->new( shapeless => 1 );
    my $store    = Fake::Store::DyingWrite->new;

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::send_reply(
            telegram   => $telegram,
            chat_id    => 999,
            text       => 'hello',
            store      => $store,
            synthesize => sub { return '/tmp/fake-voice.ogg' },
        );
    } );

    is( $err, '', 'a shapeless-but-present voice result does not die and does not log a STORE ERROR' );
    ok( defined $result, 'send_reply returns normally for a shapeless (present hashref, no message_id) voice result' );
    is_deeply( [ grep { $_->[0] eq 'record_sent_voice' } @{ $store->{calls} } ], [],
        'record_sent_voice is not attempted when the voice result carries no message_id, but this is not an error' );
}

# A Codex QA-stage review finding (round 4): the malformed/shapeless
# ref()-check fix above only had coverage for send_reply - resend_voice
# was changed identically but left completely untested for these two
# shapes, the exact same "duplicate call site left uncovered" mistake
# this ticket's own history already made once (see the send_reply-only
# coverage gap fixed earlier in this file). Both blocks mirror
# send_reply's own two blocks above.
{
    my $telegram = Fake::Telegram::MalformedVoiceResult->new;
    my $store    = Fake::Store::DyingWrite->new;

    my ( $err, $result ) = capture_stderr( sub {
        return eval {
            D2TG::Reply::resend_voice(
                telegram             => $telegram,
                chat_id              => 999,
                text                 => 'hello',
                store                => $store,
                synthesize           => sub { return '/tmp/fake-voice.ogg' },
                reply_to_message_id  => 42,
                text_message_id      => 501,
            );
        };
    } );

    my $eval_error = $@;
    ok( !defined $result, 'resend_voice dies (returns nothing) on a malformed send_voice result - it is not silently reported as success' );
    like( $eval_error, qr/unexpected result/, 'the die names the actual problem - an unexpected (non-hashref) send_voice result' );
    unlike( $err, qr/STORE ERROR/, 'this failure is never misreported as a STORE ERROR - it is not a store-write problem at all' );
    is_deeply( [ grep { $_->[0] eq 'record_sent_voice' } @{ $store->{calls} } ], [],
        'record_sent_voice is never attempted at all when send_voice returned a malformed (non-hashref) result' );
}

{
    my $telegram = Fake::ReplyTelegram->new( shapeless => 1 );
    my $store    = Fake::Store::DyingWrite->new;

    my ( $err, $result ) = capture_stderr( sub {
        return D2TG::Reply::resend_voice(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hello',
            store                => $store,
            synthesize           => sub { return '/tmp/fake-voice.ogg' },
            reply_to_message_id  => 42,
            text_message_id      => 501,
        );
    } );

    is( $err, '', 'resend_voice: a shapeless-but-present voice result does not die and does not log a STORE ERROR' );
    ok( defined $result, 'resend_voice returns normally for a shapeless (present hashref, no message_id) voice result' );
    is_deeply( [ grep { $_->[0] eq 'record_sent_voice' } @{ $store->{calls} } ], [],
        'record_sent_voice is not attempted when the voice result carries no message_id, but this is not an error' );
}

done_testing();
