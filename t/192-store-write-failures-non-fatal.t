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

done_testing();
