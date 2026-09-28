#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use lib "$Bin/../lib";

require D2TG::Poller::Dispatch;

# TGT-350 (found via a scheduled JOB-003 hourly bug hunt, live-reproduced):
# handle_message_reaction had no redelivery-dedup guard at all, unlike
# every sibling update-type handler - a Telegram redelivery of the same
# reaction state reprinted the identical NEW TG REACTION line every time,
# unbounded. Q-022 (Michael, 2026-09-28): fix with an in-process (not
# persisted) $seen_reactions hashref, optional and undef by every
# pre-existing caller so default behavior (no dedup at all) is unchanged
# unless a caller opts in - matching this project's own established
# optional-trailing-param convention (group_collect_ref, etc).

my $reaction = {
    chat_id      => 555,
    message_id   => 42,
    chat         => { id => 555 },
    user         => { username => 'alice' },
    old_reaction => [],
    new_reaction => [ { type => 'emoji', emoji => '👍' } ],
};

sub capture {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

# Case 1: no $seen_reactions passed (undef) - default behavior unchanged,
# every call prints, even an exact redelivery. This is the PRE-EXISTING
# behavior and must stay true for every caller that doesn't opt in.
{
    my $first  = capture( sub { D2TG::Poller::Dispatch::handle_message_reaction( $reaction, undef, undef ) } );
    my $second = capture( sub { D2TG::Poller::Dispatch::handle_message_reaction( $reaction, undef, undef ) } );
    like( $first,  qr/NEW TG REACTION/, 'first call prints without seen_reactions' );
    is( $second, $first, 'without seen_reactions, an identical redelivery still reprints (unchanged legacy behavior)' );
}

# Case 2: $seen_reactions passed - an identical redelivery must NOT reprint.
{
    my %seen;
    my $first  = capture( sub { D2TG::Poller::Dispatch::handle_message_reaction( $reaction, undef, undef, \%seen ) } );
    my $second = capture( sub { D2TG::Poller::Dispatch::handle_message_reaction( $reaction, undef, undef, \%seen ) } );
    like( $first, qr/NEW TG REACTION/, 'first call prints and records into seen_reactions' );
    is( $second, '', 'identical redelivery with seen_reactions produces no output (deduped)' );
}

# Case 3: a genuinely DIFFERENT reaction (new emoji added) on the same
# message must still print, even with seen_reactions populated from the
# prior state - this is a real change, not a redelivery.
{
    my %seen;
    capture( sub { D2TG::Poller::Dispatch::handle_message_reaction( $reaction, undef, undef, \%seen ) } );

    my $changed = {
        %$reaction,
        old_reaction => $reaction->{new_reaction},
        new_reaction => [ { type => 'emoji', emoji => '👍' }, { type => 'emoji', emoji => '❤' } ],
    };
    my $out = capture( sub { D2TG::Poller::Dispatch::handle_message_reaction( $changed, undef, undef, \%seen ) } );
    like( $out, qr/NEW TG REACTION/, 'a genuine reaction change still prints even with seen_reactions populated' );
}

done_testing();
