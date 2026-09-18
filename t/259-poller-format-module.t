use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-259: D2TG::Poller.pm had grown to 1604 lines. Its 13-sub stdout-
# formatting cluster (no poll-loop state, pure functions of their
# inputs) is the largest cleanly-separable concern - this proves the
# extracted D2TG::Poller::Format module works standalone.
require D2TG::Poller::Format;

# --- display_name ---
{
    local $ENV{D2TG_CHAT_ID} = '111';
    local $ENV{D2TG_OWNER}   = 'Michael';
    is( D2TG::Poller::Format::display_name( '111', 'someuser' ), 'Michael', 'owner chat_id gets D2TG_OWNER' );
    is( D2TG::Poller::Format::display_name( '222', 'someuser' ), 'someuser', 'non-owner chat_id gets the username' );
    is( D2TG::Poller::Format::display_name( '222', undef ), 'unknown', 'no username falls back to unknown' );
}

# --- timestamp_prefix ---
{
    like( D2TG::Poller::Format::timestamp_prefix( { date => 1000000000 } ), qr/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]$/, 'timestamp_prefix formats a bracketed timestamp' );
}

# --- sanitize_for_stdout ---
{
    is( D2TG::Poller::Format::sanitize_for_stdout("line1\nline2\r\n"), 'line1\nline2\n', "newlines become literal backslash-n" );
    is( D2TG::Poller::Format::sanitize_for_stdout("bad\x00byte"), 'badbyte', 'control chars are stripped' );
}

# --- bot_flag ---
{
    is( D2TG::Poller::Format::bot_flag(undef), '', 'no bot_token gives an empty flag fragment' );
    like( D2TG::Poller::Format::bot_flag('secrettoken1234'), qr/^ --bot /, 'bot_token gives a --bot flag fragment' );
    unlike( D2TG::Poller::Format::bot_flag('secrettoken1234'), qr/secrettoken1234/, 'the raw token is never present in the returned fragment' );
}

# --- reaction_key / reaction_label ---
{
    is( D2TG::Poller::Format::reaction_key( { type => 'emoji', emoji => '👍' } ), 'emoji:👍', 'reaction_key for an emoji reaction' );
    is( D2TG::Poller::Format::reaction_key( { type => 'paid' } ), 'paid', 'reaction_key for a paid reaction' );
    is( D2TG::Poller::Format::reaction_label( { type => 'emoji', emoji => '👍' } ), '👍', 'reaction_label for an emoji reaction' );
    is( D2TG::Poller::Format::reaction_label( { type => 'custom_emoji' } ), 'a custom emoji', 'reaction_label for a custom emoji' );
}

# --- forward_origin_name ---
{
    is( D2TG::Poller::Format::forward_origin_name(undef), undef, 'no origin returns undef' );
    is( D2TG::Poller::Format::forward_origin_name( { type => 'user', sender_user => { username => 'alice' } } ), 'alice', 'user origin prefers username' );
    is( D2TG::Poller::Format::forward_origin_name( { type => 'hidden_user', sender_user_name => 'Bob' } ), 'Bob', 'hidden_user origin uses sender_user_name' );
}

# --- format_forwarded_sender ---
{
    is( D2TG::Poller::Format::format_forwarded_sender( 'alice', undef ), 'alice', 'no forward_origin leaves sender unchanged' );
    is(
        D2TG::Poller::Format::format_forwarded_sender( 'alice', { type => 'user', sender_user => { username => 'bob' } } ),
        'bob (forwarded by alice)',
        'forwarded message attributes to the original sender'
    );
}

# --- media_kind ---
{
    is( D2TG::Poller::Format::media_kind( { photo => [1] } ),    'photo',    'media_kind detects photo' );
    is( D2TG::Poller::Format::media_kind( { document => {} } ),  'document', 'media_kind detects document' );
    is( D2TG::Poller::Format::media_kind( { voice => {} } ),     'voice',    'media_kind detects voice' );
    is( D2TG::Poller::Format::media_kind( { video => {} } ),     'video',    'media_kind detects video' );
    is( D2TG::Poller::Format::media_kind( {} ),                  undef,      'no recognized media returns undef' );
}

# --- stored_summary ---
{
    package Fake::Store::ForStoredSummary;
    sub new { return bless {}, shift }
    sub get_message { return { summary => 'a summary' } }
}
{
    my $store = Fake::Store::ForStoredSummary->new;
    is( D2TG::Poller::Format::stored_summary( $store, 111, 5, undef ), 'a summary', 'stored_summary reads through to the store' );
    is( D2TG::Poller::Format::stored_summary( undef, 111, 5, undef ), undef, 'no store returns undef' );
}

# TGT-306 (found via a JOB-004 improvement-hunt pass that surfaced a
# genuine bug): stored_summary's own $store->get_message call ran
# unwrapped - the same raw-crash/db-path-leak risk TGT-183/186/195/293
# already fixed for other call sites, missed here because TGT-293's own
# sweep scoped only to cli/*.pl scripts, never lib/*.pm internals. A
# locked/busy database here must degrade gracefully (returning undef,
# same as a legitimate "no row" result) rather than dying.
{
    package Fake::Store::DiesOnGetMessage;
    sub new { return bless {}, shift }
    sub get_message { die "database is locked\n" }
}
{
    my $store = Fake::Store::DiesOnGetMessage->new;
    is( D2TG::Poller::Format::stored_summary( $store, 111, 5, undef ), undef,
        'stored_summary degrades gracefully (returns undef) when the store dies, instead of propagating the raw exception' );

    # Exercise the full reply_context_suffix cluster too, confirming the
    # graceful degradation reaches the existing no-lookup fallback path.
    local $ENV{D2TG_CHAT_ID} = undef;
    local $ENV{D2TG_OWNER}   = undef;
    my $message = { reply_to_message => { from => { username => 'bob' }, message_id => 9, text => 'fallback text' } };
    my $suffix = D2TG::Poller::Format::reply_context_suffix( $message, $store, 111, undef );
    is( $suffix, ' (replying to bob [msg #9]: fallback text)',
        'reply_context_suffix falls back to the raw message text when the store lookup dies, instead of dying itself' );
}

# --- reply_context_suffix (exercises the whole cluster together) ---
{
    local $ENV{D2TG_CHAT_ID} = undef;
    local $ENV{D2TG_OWNER}   = undef;
    my $message = { reply_to_message => { from => { username => 'alice' }, message_id => 7, text => 'hello there' } };
    my $suffix = D2TG::Poller::Format::reply_context_suffix( $message, undef, 111, undef );
    is( $suffix, ' (replying to alice [msg #7]: hello there)', 'reply_context_suffix composes the full reply-context line' );
    is( D2TG::Poller::Format::reply_context_suffix( { reply_to_message => undef }, undef, 111, undef ), '', 'no reply_to_message gives an empty suffix' );
}

done_testing();
