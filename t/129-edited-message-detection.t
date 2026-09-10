use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

# TGT-169 (live Telegram question from Michael, msg #246): "is the
# implementable if the user on telegram edit the previous message and
# that will notify the agent about the updated message". Telegram's
# Bot API sends a distinct edited_message update (same shape as an
# ordinary message but reflecting the post-edit content) whenever an
# allow-listed sender edits a message the bot already received -
# genuinely detectable, unlike deletion (no such update exists at all).

sub capture_stdout {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

{
    # An allow-listed sender edits a message - a distinct NEW TG EDIT
    # line must be printed with the new content.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 1000,
                edited_message => {
                    message_id => 55,
                    date       => 1_700_000_000,
                    chat       => { id => 444 },
                    from       => { username => 'ada' },
                    text       => 'corrected text',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [444] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG EDIT \[444\] ada: corrected text \(msg #55, edited\)/,
        'an edited message from an allow-listed sender prints a distinct NEW TG EDIT line with the new content' );
    ok( $store->get_message( 444, 55 ),
        'the edited message content is recorded in the store, so d2 tg.history reflects the edit' );
}

{
    # Codex review finding: a caption/media-only edit (no text field at
    # all) must NOT overwrite an already-correct history summary with
    # the literal '(no text)' placeholder - it is still announced, but
    # deliberately not recorded, since this narrow ticket only handles
    # text edits' own history update.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 1002,
                edited_message => {
                    message_id => 57,
                    date       => 1_700_000_000,
                    chat       => { id => 666 },
                    from       => { username => 'carl' },

                    # No 'text' field at all - a caption/media-only edit.
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [666] );
    $store->record_message( 666, 57, 'carl', 'original document summary' );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG EDIT \[666\] carl: \(no text\) \(msg #57, edited\)/,
        'a caption/media-only edit is still announced' );
    is( $store->get_message( 666, 57 )->{summary}, 'original document summary',
        'a caption/media-only edit does NOT overwrite the existing, already-correct history summary' );
}

{
    # is_allowed dies (e.g. a locked database) while processing an
    # edited_message - matching TGT-165's own established pattern for
    # the plain message/message_reaction branches, this must not
    # propagate or abort the batch; the edit is skipped non-fatally.
    package Fake::Store::DyingIsAllowed;

    sub new { return bless { dies_for => $_[1]{dies_for} }, $_[0]; }

    sub is_allowed {
        my ( $self, $id ) = @_;
        die "database is locked\n" if defined $self->{dies_for} && $id == $self->{dies_for};
        return 0;
    }

    package main;

    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 1003,
                edited_message => {
                    message_id => 58,
                    date       => 1_700_000_000,
                    chat       => { id => 777 },
                    from       => { username => 'dana' },
                    text       => 'edited during a locked database',
                },
            },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new( { dies_for => 777 } );

    my $lived = eval {
        capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );
        1;
    };

    ok( $lived, 'run_once survives is_allowed dying while processing an edited_message' );
}

{
    # An unapproved sender edits a message - gated the same way the
    # plain message branch already is (silently ignored, matching
    # message_reaction's own established precedent for a non-first-
    # contact event - no add_pending, since the original message
    # already established (or failed to establish) contact).
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 1001,
                edited_message => {
                    message_id => 56,
                    date       => 1_700_000_000,
                    chat       => { id => 555 },
                    from       => { username => 'eve' },
                    text       => 'edited by an unapproved sender',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    unlike( $out, qr/NEW TG EDIT/, 'an edited message from an unapproved sender is not announced' );
    unlike( $out, qr/NEW TG PENDING/, 'an edit does not queue a pending-approval notice - it is not a first-contact event' );
}

done_testing();
