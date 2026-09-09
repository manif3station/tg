use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use JSON::PP qw(decode_json);
use HTTP::Response;

require D2TG::Telegram;
require D2TG::Poller;
use Fake::Telegram;
use Fake::UA;

# TGT-143 (live Telegram question, msg #176, Michael: "the user can
# give a like or mark a message with emoji, is that something can be
# implement to pick this up and print out the to stdout if detected?").
# Confirmed via direct code read: D2TG::Telegram::get_updates never set
# allowed_updates at all, so message_reaction updates (Bot API's opt-in
# reaction-change type) never reached the poller regardless of whether
# a user reacted - not a platform limitation, a missing request param.

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} ) if defined $args{content};
    return $res;
}

{
    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":[]}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    $tg->get_updates( offset => 1 );

    my $sent_body = decode_json( $ua->{calls}[0]{req}->content );
    ok( exists $sent_body->{allowed_updates}, 'get_updates now requests allowed_updates explicitly' );
    my %requested = map { $_ => 1 } @{ $sent_body->{allowed_updates} // [] };
    ok( $requested{message}, 'allowed_updates preserves the existing message update type - never silently dropped' );
    ok( $requested{message_reaction}, 'allowed_updates now includes message_reaction' );
}

sub _run_and_capture {
    my ($update) = @_;
    my $telegram = Fake::Telegram->new( [$update] );
    my @lines;
    {
        local *STDOUT;
        open STDOUT, '>', \my $captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, undef );
        close STDOUT;
        @lines = split /\n/, $captured;
    }
    return $lines[0] // '';
}

{
    # A reaction ADD: new_reaction is non-empty.
    my $update = {
        update_id       => 1,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 42,
            user            => { username => 'reactor_a' },
            old_reaction    => [],
            new_reaction    => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/NEW TG REACTION \[999\] reactor_a: 👍 on message 42/,
        'a reaction add prints a NEW TG REACTION line naming the sender, emoji, and message' );
}

{
    # A reaction REMOVE: new_reaction is empty, old_reaction had one.
    my $update = {
        update_id       => 2,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 42,
            user            => { username => 'reactor_a' },
            old_reaction    => [ { type => 'emoji', emoji => '👍' } ],
            new_reaction    => [],
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/REACTION REMOVED \[999\] reactor_a: 👍 on message 42/,
        'a reaction removal is distinguishable from an add' );
}

{
    # Codex review finding: MessageReactionUpdated reports the FULL
    # current/previous reaction sets, not a single before/after pair -
    # a user can swap one emoji for another in a single update
    # ([👍] -> [👎]), which is simultaneously a removal AND an add, not
    # just "any non-empty new_reaction means an add".
    my $update = {
        update_id       => 4,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 44,
            user            => { username => 'reactor_b' },
            old_reaction    => [ { type => 'emoji', emoji => '👍' } ],
            new_reaction    => [ { type => 'emoji', emoji => '👎' } ],
        },
    };

    my $telegram = Fake::Telegram->new( [$update] );
    my @lines;
    {
        local *STDOUT;
        open STDOUT, '>', \my $captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, undef );
        close STDOUT;
        @lines = grep { length } split /\n/, $captured;
    }

    is( scalar(@lines), 2, 'swapping one reaction for another produces exactly 2 lines (one add, one remove)' );
    ok( ( grep { /NEW TG REACTION \[999\] reactor_b: 👎 on message 44/ } @lines ), 'the newly-added emoji is reported' );
    ok( ( grep { /REACTION REMOVED \[999\] reactor_b: 👍 on message 44/ } @lines ), 'the removed emoji is reported separately' );
}

{
    # Codex review finding: sender/emoji must be sanitized before
    # reaching stdout, matching every other untrusted string this
    # poller prints (a Telegram username is attacker-controlled).
    my $update = {
        update_id       => 5,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 45,
            user            => { username => "Evil\nName" },
            old_reaction    => [],
            new_reaction    => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $line = _run_and_capture($update);
    unlike( $line, qr/\n.*\n/s, 'a hostile reactor username with an embedded newline never breaks the single printed line' );
    like( $line, qr/Evil\\nName/, 'the newline is escaped visibly, matching _sanitize_for_stdout\'s own convention' );
}

{
    # Codex review finding: ReactionType is a tagged union - type=emoji
    # carries an emoji glyph, but type=custom_emoji carries a distinct
    # custom_emoji_id with no emoji field at all. Keying/diffing on
    # emoji alone would collapse two DIFFERENT custom emojis into the
    # same bucket, silently hiding a real swap between them.
    my $update = {
        update_id       => 6,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 46,
            user            => { username => 'reactor_c' },
            old_reaction    => [ { type => 'custom_emoji', custom_emoji_id => 'AAA' } ],
            new_reaction    => [ { type => 'custom_emoji', custom_emoji_id => 'BBB' } ],
        },
    };

    my $telegram = Fake::Telegram->new( [$update] );
    my @lines;
    {
        local *STDOUT;
        open STDOUT, '>', \my $captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, undef );
        close STDOUT;
        @lines = grep { length } split /\n/, $captured;
    }

    is( scalar(@lines), 2,
        'swapping between two DIFFERENT custom emojis is detected as a real change (add + remove), not silently collapsed to no change' );
}

{
    # A single, unchanged custom_emoji reaction (no real change at all)
    # must genuinely produce zero lines - proving the fix does not
    # over-report every custom_emoji reaction as constantly changing.
    my $update = {
        update_id       => 7,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 47,
            user            => { username => 'reactor_d' },
            old_reaction    => [ { type => 'custom_emoji', custom_emoji_id => 'AAA' } ],
            new_reaction    => [ { type => 'custom_emoji', custom_emoji_id => 'AAA' } ],
        },
    };

    my $telegram = Fake::Telegram->new( [$update] );
    my $captured;
    {
        local *STDOUT;
        open STDOUT, '>', \$captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, undef );
        close STDOUT;
    }
    is( $captured // '', '', 'an unchanged custom_emoji reaction (same id both sides) produces no output at all' );
}

{
    # A 'paid' reaction (no emoji glyph, no distinguishing id either -
    # every paid reaction shares the same key by design).
    my $update = {
        update_id       => 8,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 48,
            user            => { username => 'reactor_e' },
            old_reaction    => [],
            new_reaction    => [ { type => 'paid' } ],
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/NEW TG REACTION \[999\] reactor_e: a paid reaction on message 48/,
        'a paid reaction (no emoji glyph) prints a plain description' );
}

{
    # An unrecognized/future ReactionType (a Bot API addition this
    # code doesn't know about yet) must not crash or be silently
    # dropped - falls back to a plain, honest description.
    my $update = {
        update_id       => 9,
        message_reaction => {
            chat            => { id => 999 },
            message_id      => 49,
            user            => { username => 'reactor_f' },
            old_reaction    => [],
            new_reaction    => [ { type => 'some_future_reaction_type' } ],
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/NEW TG REACTION \[999\] reactor_f: an unrecognized reaction type on message 49/,
        'an unrecognized ReactionType falls back to a plain, honest description rather than crashing or being dropped' );
}

{
    # An ordinary message update must be entirely unaffected.
    my $update = {
        update_id => 3,
        message   => {
            message_id => 43,
            chat        => { id => 999 },
            from        => { username => 'ordinary_sender' },
            text        => 'not a reaction',
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/NEW TG \[999\] ordinary_sender: not a reaction/,
        'an ordinary message update is completely unaffected by reaction handling' );
}

done_testing();
