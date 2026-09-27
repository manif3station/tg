use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Poller::Dispatch;

# TGT-343 (found via a scheduled JOB-004 improvement hunt, extending
# TGT-313's own "found it twice, extract it" precedent one branch
# further): _record_media_and_announce is the shared helper the
# downloaded-media and fallback-media branches of handle_plain_update
# both now call instead of each duplicating the record_message_and_
# track_offset call site. Unlike t/313's own thin existence-only test
# (whose two branches are both already exercised by the wider suite via
# handle_plain_update itself), this helper has one genuinely new branch
# - group_collect_ref - that nothing calls it with yet anywhere in the
# codebase, since handle_media_group_update (the future caller) doesn't
# exist yet either. This test exercises both branches directly so the
# 100% stmt+sub coverage gate stays satisfied ahead of that wiring.

package MockStore;
sub new    { return bless {}, shift }
my @recorded;
sub record_message_and_track_offset_called { return @recorded }
package main;

{
    no strict 'refs';
    no warnings 'redefine';
    *D2TG::Poller::Safe::record_message_and_track_offset = sub {
        my ( $store, $offset_cap_ref, $update_id, $chat_id, $message_id, $sender, $summary, %opts ) = @_;
        push @recorded, { chat_id => $chat_id, message_id => $message_id, summary => $summary, %opts };
        return;
    };
}

subtest 'group mode: announce is suppressed, an entry is pushed instead, store write still happens' => sub {
    @recorded = ();
    my @collected;
    my $store = MockStore->new;
    my $offset_cap;

    my $out = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        D2TG::Poller::Dispatch::_record_media_and_announce(
            ts                => '[2026-09-27T01:00:00]',
            chat_id           => 111,
            sender            => 'ada',
            msg_note          => ' (msg #5)',
            reply_ctx         => '',
            message_id        => 5,
            media_kind        => 'photo',
            caption_note      => '',
            store             => $store,
            offset_cap_ref    => \$offset_cap,
            update_id         => 1001,
            bot_token         => 'TOK',
            local_path        => '/vault/abc.jpg',
            group_collect_ref => \@collected,
        );
    }

    is( $out, '', 'group mode: nothing printed to stdout for this individual part' );
    is( scalar(@collected), 1, 'group mode: one entry pushed to the collector' );
    is( $collected[0]{chat_id},    111,     'collected entry has the right chat_id' );
    is( $collected[0]{message_id}, 5,       'collected entry has the right message_id' );
    is( $collected[0]{media_kind}, 'photo', 'collected entry has the right media_kind' );
    is( scalar(@recorded), 1, 'the store write still happened even though the announce was suppressed' );
    is( $recorded[0]{local_path}, '/vault/abc.jpg', 'the store write still carries local_path' );
};

subtest 'non-group mode (group_collect_ref absent): prints the announce as before, no collector touched' => sub {
    @recorded = ();
    my $store = MockStore->new;
    my $offset_cap;

    my $out = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        D2TG::Poller::Dispatch::_record_media_and_announce(
            ts             => '[2026-09-27T01:00:00]',
            chat_id        => 222,
            sender         => 'bob',
            msg_note       => ' (msg #9)',
            reply_ctx      => '',
            message_id     => 9,
            media_kind     => 'document',
            caption_note   => '',
            store          => $store,
            offset_cap_ref => \$offset_cap,
            update_id      => 1002,
            bot_token      => 'TOK',
        );
    }

    like( $out, qr/NEW TG MEDIA \[222\] bob: document \(msg #9\)/, 'non-group mode: the individual announce line is printed' );
    is( scalar(@recorded), 1, 'the store write still happened' );
    ok( !exists $recorded[0]{local_path}, 'no local_path key at all when none was passed (fallback-branch shape)' );
};

done_testing();
