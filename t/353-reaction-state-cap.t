#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use lib "$Bin/../lib";

require D2TG::Poller::Dispatch;

# TGT-352 (found via a scheduled JOB-004 improvement hunt, reviewing
# TGT-350's own fresh diff): $seen_reactions (an optional, caller-owned
# hashref) gained no eviction path when TGT-350 introduced it - a
# long-running poller process would accumulate one entry per distinct
# (chat_id, message_id, bot_token) reaction ever seen, unbounded, for
# the life of the process. Capped at
# D2TG::Poller::Dispatch::MAX_REACTION_STATE_ENTRIES entries - once
# reached, the whole hash is cleared before the next entry is recorded
# (a simple wrap-around cap, not a persisted table - matches Q-022's
# own explicit no-new-table tradeoff; at most one extra duplicate
# announce right after a wrap, versus unbounded growth otherwise).

sub silent {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return;
}

my $cap = D2TG::Poller::Dispatch::MAX_REACTION_STATE_ENTRIES();
ok( $cap > 0, 'MAX_REACTION_STATE_ENTRIES is a positive cap' );

my %seen;
for my $i ( 1 .. $cap ) {
    my $reaction = {
        chat_id      => $i,
        message_id   => $i,
        chat         => { id => $i },
        user         => { username => 'alice' },
        old_reaction => [],
        new_reaction => [ { type => 'emoji', emoji => '1' } ],
    };
    silent( sub { D2TG::Poller::Dispatch::handle_message_reaction( $reaction, undef, undef, \%seen ) } );
}

is( scalar keys %seen, $cap, "hash holds exactly $cap entries right at the cap" );

# One more distinct entry past the cap must not grow the hash beyond
# the cap - it wraps (clears, then records just the new one).
my $one_more = {
    chat_id      => $cap + 1,
    message_id   => $cap + 1,
    chat         => { id => $cap + 1 },
    user         => { username => 'alice' },
    old_reaction => [],
    new_reaction => [ { type => 'emoji', emoji => '1' } ],
};
silent( sub { D2TG::Poller::Dispatch::handle_message_reaction( $one_more, undef, undef, \%seen ) } );

cmp_ok( scalar keys %seen, '<=', $cap, 'hash never exceeds the cap, even after inserting one more distinct entry' );

done_testing();
