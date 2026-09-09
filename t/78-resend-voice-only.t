use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile tempdir);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Reply;
require Fake::ReplyTelegram;

# TGT-109 (live-experienced incident, user-supplied /tmp/missing2.md,
# item 3): TGT-083 orders send_reply as text-first-then-voice, so a
# voice failure after text success currently has no clean recovery path
# - re-running d2 tg.reply would duplicate the already-delivered text.
# resend_voice() must synthesize and send ONLY the voice half for an
# already-sent message, never touching send_message at all.

package Fake::Store;

sub new { return bless { marked_read => [] }, shift }

sub mark_read {
    my ( $self, $chat_id, $message_id ) = @_;
    push @{ $self->{marked_read} }, { chat_id => $chat_id, message_id => $message_id };
    return;
}

package main;

{
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram   = Fake::ReplyTelegram->new;
    my $synthesize = sub {
        push @{ $telegram->{call_order} }, 'synthesize';
        return $voice_path;
    };

    my $result = D2TG::Reply::resend_voice(
        telegram   => $telegram,
        chat_id    => 99,
        text       => 'hello there',
        synthesize => $synthesize,
    );

    is_deeply( $telegram->{call_order}, [ 'synthesize', 'send_voice' ],
        'resend_voice calls synthesize then send_voice - never send_message' );
    is( scalar @{ $telegram->{sent_messages} }, 0, 'no text message was ever sent' );
    is( scalar @{ $telegram->{sent_voices} },   1, 'exactly one voice note was sent' );
    ok( $result->{voice}, 'resend_voice returns the voice send result' );
    ok( !exists $result->{text}, 'resend_voice returns no text result - it never sent one' );
}

{
    # Codex review finding: a recovered reply must not stay unread
    # forever - mark_read must fire after a successful resend, and
    # reply_to_message_id must thread through to send_voice so the
    # resent voice note still lands as a native Telegram reply.
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram   = Fake::ReplyTelegram->new;
    my $store      = Fake::Store->new;
    my $synthesize = sub { return $voice_path };

    D2TG::Reply::resend_voice(
        telegram             => $telegram,
        chat_id              => 99,
        text                 => 'hello there',
        synthesize           => $synthesize,
        reply_to_message_id  => 42,
        store                => $store,
    );

    is( $telegram->{sent_voices}[0]{reply_to_message_id}, 42,
        'reply_to_message_id is forwarded to send_voice on the recovery path' );
    is_deeply( $store->{marked_read}, [ { chat_id => 99, message_id => 42 } ],
        'mark_read fires after a successful voice-only resend - the reply does not stay unread forever' );
}

{
    # And the inverse: a FAILED resend must never mark anything read -
    # matching send_reply's own "never marked read for a reply that
    # didn't actually go out" guarantee.
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram   = Fake::ReplyTelegram->new( fail_voice => 1 );
    my $store      = Fake::Store->new;
    my $synthesize = sub { return $voice_path };

    eval {
        D2TG::Reply::resend_voice(
            telegram             => $telegram,
            chat_id              => 99,
            text                 => 'hello there',
            synthesize           => $synthesize,
            reply_to_message_id  => 42,
            store                => $store,
        );
    };

    is( scalar @{ $store->{marked_read} }, 0, 'a failed voice-only resend never marks the message read' );
}

{
    # Failure still propagates loudly, matching send_reply's own
    # fail-loud convention - never a silent "looks fine" success.
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram   = Fake::ReplyTelegram->new( fail_voice => 1 );
    my $synthesize = sub { return $voice_path };

    eval {
        D2TG::Reply::resend_voice(
            telegram   => $telegram,
            chat_id    => 99,
            text       => 'hello there',
            synthesize => $synthesize,
        );
    };
    like( $@, qr/sendVoice failed/, 'a send_voice failure on resend still dies loudly' );
    is( scalar @{ $telegram->{sent_messages} }, 0, 'still no text message sent, even on failure' );
    ok( !-e $voice_path, 'the temp voice file is cleaned up even on failure' );
}

{
    # CLI-level integration: --voice-only is recognized and consumed by
    # the leading-flag parser, matching --db/--bot's own shape - proven
    # here via the Usage-refusal path (no network call, matching this
    # project's established no-real-network-in-tests convention for
    # cli/reply.pl - a full successful send is tested at the lib level
    # above via a mocked Telegram object, not through the CLI process).
    my $reply_cli   = File::Spec->catfile( $Bin, '..', 'cli', 'reply.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $err_file = "/tmp/d2tg-78-stderr.$$";
    my $out      = `$reply_cli --voice-only 2>$err_file`;
    my $rc       = $? >> 8;
    my $err      = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;

    is( $rc, 2, '--voice-only with no chat_id/text still hits the same Usage refusal (flag consumed, not misparsed as chat_id)' );
    like( $err, qr/Usage: d2 tg\.reply/, 'Usage message printed, --voice-only did not break argument parsing' );
}

done_testing();
