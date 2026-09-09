use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Store;
require D2TG::Reply;

# TGT-105: TGT-083 deliberately reordered D2TG::Reply::send_reply to
# send text first, then synthesize+send voice - a synthesis/send_voice
# failure after that point can leave a reply text-only, always reported
# loudly (non-zero exit) AT SEND TIME. This ticket closes the gap for
# AFTER send time: if that loud failure is missed, there is currently no
# persisted record anywhere that would let a later check catch the
# resulting text-only reply.

my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

is_deeply( $store->text_only_replies, [], 'text_only_replies starts empty' );

$store->record_sent_text( 999, 501 );
my $list = $store->text_only_replies;
is( scalar @$list, 1, 'a text-only send (no matching voice yet) is flagged' );
is( $list->[0]{chat_id},         999, 'flagged row carries chat_id' );
is( $list->[0]{text_message_id}, 501, 'flagged row carries the text message_id' );
ok( $list->[0]{created_at}, 'flagged row carries a created_at timestamp' );

$store->record_sent_voice( 999, 501, 777 );
is_deeply( $store->text_only_replies, [], 'recording the matching voice send clears the text-only flag' );

$store->record_sent_text( 1000, 502 );
$store->record_sent_text( 1000, 503 );
$store->record_sent_voice( 1000, 502, 778 );
my $still_flagged = $store->text_only_replies;
is( scalar @$still_flagged, 1, 'only the reply still missing its voice half is flagged' );
is( $still_flagged->[0]{text_message_id}, 503, 'the correct (voice-missing) reply is the one flagged' );

# Codex review finding: bot isolation, mirroring TGT-098's own lesson -
# a Telegram group shared by more than one configured bot means chat_id
# alone isn't unique across bots. Bot A's own text-only flag for a
# chat_id must not be visible/clearable via bot B's own lookup.
{
    my $bot_store = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );

    $bot_store->record_sent_text( 999, 900, bot_key => 'bot-a-token' );
    $bot_store->record_sent_text( 999, 900, bot_key => 'bot-b-token' );

    my $bot_a_flagged = $bot_store->text_only_replies( bot_key => 'bot-a-token' );
    my $bot_b_flagged = $bot_store->text_only_replies( bot_key => 'bot-b-token' );
    is( scalar @$bot_a_flagged, 1, 'bot A has its own flagged row for the shared chat_id/text_message_id' );
    is( scalar @$bot_b_flagged, 1, 'bot B independently has its own flagged row for the same chat_id/text_message_id' );

    $bot_store->record_sent_voice( 999, 900, 950, bot_key => 'bot-a-token' );
    is_deeply( $bot_store->text_only_replies( bot_key => 'bot-a-token' ), [], "clearing bot A's flag does not affect bot B" );
    is( scalar @{ $bot_store->text_only_replies( bot_key => 'bot-b-token' ) }, 1, "bot B's own flag is untouched by bot A's recovery" );

    my $all = $bot_store->text_only_replies;
    is( scalar @$all, 1, 'omitting bot_key lists every bot\'s still-flagged rows (bot B\'s, since bot A\'s was cleared)' );
    is( $all->[0]{bot_key}, 'bot-b-token', 'the listed row correctly names its own bot_key' );
}

# Codex review finding: record_sent_voice against a non-existent row
# (wrong bot_key, or the text row was never recorded at all) must warn,
# not silently succeed and hide the gap.
{
    my $warn_store = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $warn_store->record_sent_voice( 999, 999999, 111 );

    is( scalar @warnings, 1, 'record_sent_voice warns when no matching row exists' );
    like( $warnings[0], qr/no matching sent_replies row/, 'the warning explains the gap' );
}

# Re-recording the same (chat_id, text_message_id) must not create a
# duplicate row (mirrors TGT-104's own dedup precedent).
$store->record_sent_text( 1000, 503 );
is( scalar @{ $store->text_only_replies }, 1, 'recording the same text send again does not duplicate the row' );

# D2TG::Reply::send_reply wiring: a complete reply is never flagged; a
# reply whose voice half fails IS flagged (and reported loudly, per
# TGT-083's own tradeoff - the die still happens).
package Fake::ReplyTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { fail_voice => $args{fail_voice} }, $class;
}

sub send_message {
    my ( $self, $chat_id, $text ) = @_;
    return [ { message_id => 601 } ];
}

sub send_voice {
    my ( $self, $chat_id, $path ) = @_;
    die "sendVoice failed: network error\n" if $self->{fail_voice};
    return { message_id => 701 };
}

package main;

{
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $store    = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    my $telegram = Fake::ReplyTelegram->new;

    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'hello',
        synthesize => sub { return $voice_path },
        store      => $store,
    );

    is_deeply( $store->text_only_replies, [], 'a complete send_reply (text + voice both succeed) is never flagged' );
}

{
    my $store    = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    my $telegram = Fake::ReplyTelegram->new( fail_voice => 1 );

    eval {
        D2TG::Reply::send_reply(
            telegram   => $telegram,
            chat_id    => 999,
            text       => 'hello',
            synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
            store      => $store,
        );
    };
    like( $@, qr/sendVoice failed/, 'send_reply still dies loudly on a voice failure (TGT-083 tradeoff unchanged)' );

    my $flagged = $store->text_only_replies;
    is( scalar @$flagged, 1, 'the text-only outcome is flagged even though send_reply died' );
    is( $flagged->[0]{text_message_id}, 601, 'the flagged row names the text message that actually went out' );
}

# CLI-level: d2 tg.reply --voice-only clears the flag on success.
{
    my $store    = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    $store->record_sent_text( 999, 601 );
    is( scalar @{ $store->text_only_replies }, 1, 'sanity: the text-only row exists before recovery' );

    my $telegram = Fake::ReplyTelegram->new;
    my ($latest_text_only) =
      sort { $b->{text_message_id} <=> $a->{text_message_id} }
      grep { $_->{chat_id} == 999 } @{ $store->text_only_replies };

    D2TG::Reply::resend_voice(
        telegram        => $telegram,
        chat_id         => 999,
        text            => 'hello',
        synthesize      => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
        store           => $store,
        text_message_id => $latest_text_only->{text_message_id},
    );

    is_deeply( $store->text_only_replies, [], 'resend_voice recovering the voice half clears the text-only flag' );
}

# CLI-level: d2 tg.text-only-replies lists and exits accordingly.
{
    my $cli         = File::Spec->catfile( $Bin, '..', 'cli', 'text-only-replies.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    {
        my $out = `$cli`;
        my $rc  = $? >> 8;
        is( $out, "No text-only replies found.\n", 'reports clean when nothing is flagged' );
        is( $rc, 0, 'exits 0 when clean' );
    }

    {
        my $store = D2TG::Store->new(
            db_path       => File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.messages.db' ),
            admin_chat_id => 12345,
        );
        $store->record_sent_text( 999, 601 );
        $store->disconnect;

        my $out = `$cli`;
        my $rc  = $? >> 8;
        like( $out, qr/chat_id=999/,   'lists the flagged chat_id' );
        like( $out, qr/msg #601/,      'lists the flagged text message_id' );
        isnt( $rc, 0, 'exits non-zero when something is flagged' );
    }

    {
        my ( $out, $rc ) = ( `$cli --bogus 2>&1`, $? >> 8 );
        isnt( $rc, 0, 'an unrecognized argument refuses' );
        like( $out, qr/Usage/, 'usage refusal names the correct usage' );
    }
}

# Regression: a caller's fake $telegram whose send_message returns any
# shape (not necessarily D2TG::Telegram's own arrayref-of-hashrefs) must
# never crash send_reply, whether or not a store is given - found via
# t/32's own pre-existing Fake::TelegramForReply (returns a bare
# hashref) breaking when this feature's first draft assumed an arrayref
# unconditionally.
package Fake::ShapelessTelegram;

sub new { return bless {}, shift }
sub send_message { return { ok => 1 } }    # NOT an arrayref
sub send_voice    { return { ok => 1 } }

package main;

{
    my $telegram = Fake::ShapelessTelegram->new;

    my $result = D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'hello',
        synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
        # deliberately no store - this must not require or assume one
    );

    ok( $result, 'send_reply completes normally against a telegram whose send_message returns a non-arrayref, with no store given' );
}

{
    my $store    = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    my $telegram = Fake::ShapelessTelegram->new;

    my $result = D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'hello',
        synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
        store      => $store,
    );

    ok( $result, 'send_reply completes normally against a telegram whose send_message returns a non-arrayref, WITH a store given' );
    is_deeply( $store->text_only_replies, [], 'no crash and no flagged row when the text send result has no extractable message_id' );
}

done_testing();
