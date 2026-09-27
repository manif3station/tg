use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Poller::Format;

# TGT-345 (found via a scheduled JOB-004 improvement hunt, reviewing
# TGT-343's own fresh diff): D2TG::Poller::Dispatch::handle_plain_update
# and D2TG::Poller::MediaGroup::handle_media_group_update each duplicated
# the exact same 2-line chain - display_name($chat_id, $message->{from}
# {username}) then format_forwarded_sender($sender, $message->{
# forward_origin}) - matching this project's own "found it twice,
# extract it" convention. compute_sender($chat_id, $message) collapses
# both calls into one.

is(
    D2TG::Poller::Format::compute_sender( 999, { from => { username => 'ada' } } ),
    D2TG::Poller::Format::display_name( 999, 'ada' ),
    'compute_sender with no forward_origin matches plain display_name'
);

{
    my $message = {
        from            => { username => 'ada' },
        forward_origin  => { type => 'user', sender_user => { username => 'bob' } },
    };
    my $expected = D2TG::Poller::Format::format_forwarded_sender(
        D2TG::Poller::Format::display_name( 999, 'ada' ),
        $message->{forward_origin},
    );
    is( D2TG::Poller::Format::compute_sender( 999, $message ), $expected,
        'compute_sender with a forward_origin matches the manual display_name + format_forwarded_sender chain' );
}

done_testing();
