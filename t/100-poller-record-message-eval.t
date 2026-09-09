use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;

package Fake::ThrowingStore;

sub new {
    my ($class) = @_;
    return bless { messages => {} }, $class;
}

sub is_allowed     { return 1 }
sub add_pending     { return 1 }
sub record_message {
    die "unable to open database file: /secret/internal/path/telegram.messages.db\n";
}
sub get_message { return undef }

package main;

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

# TGT-132: run_once's own record_message calls (text/voice/media/
# fallback) weren't eval-wrapped like the sibling record_failed_download
# call - a store failure mid-batch (e.g. SQLite contention exceeding
# TGT-129's own busy_timeout) would die inside run_once, which
# run_once_safe catches by returning the offset UNCHANGED, causing the
# ENTIRE batch (including updates already printed/handled) to be
# refetched and reprinted next cycle - a duplicate NEW TG/REPLY WITH
# announcement risking a duplicate reply from the watching agent.

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 500,
                message   => { message_id => 1, chat => { id => 999 }, from => { username => 'ada' }, text => 'first message' },
            },
            {
                update_id => 501,
                message   => { message_id => 2, chat => { id => 999 }, from => { username => 'ada' }, text => 'second message' },
            },
        ],
    );
    my $store = Fake::ThrowingStore->new;

    my ( $updates, $next_offset );
    my ( $out, $err ) = capture_std( sub {
        ( $updates, $next_offset ) = D2TG::Poller::run_once( $tg, undef, $store );
    } );

    like( $out, qr/first message/,  'the first update in the batch is still printed despite record_message dying' );
    like( $out, qr/second message/, 'the second update in the batch is still printed too - the batch is not abandoned' );
    is( $next_offset, 502, 'run_once still advances the offset past the whole batch, not just up to the failure' );
    like( $err, qr/record_message/i, 'the record_message failure is reported on stderr, non-fatally' );
    unlike( $err, qr{/secret/internal/path}, 'stderr never echoes the raw exception text - a DBI error can embed the DB file path, which must never leak' );
}

done_testing();
