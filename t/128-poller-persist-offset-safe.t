use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;

# TGT-166 (found via a scheduled hourly bug-hunt, a direct follow-up
# sweep after TGT-165 for the same unwrapped-DBI-call pattern):
# cli/poller.pl's main loop called $store->set_offset(...) directly,
# with no eval wrapper - unlike run_once's own is_allowed/add_pending
# calls, which TGT-165 just fixed. set_offset runs a DBI do() against a
# RaiseError=>1 handle, so a locked/busy SQLite database made it die -
# but since this call sits at the top level of the persistent poller
# script's main loop (not inside run_once_safe's own eval), it crashed
# the ENTIRE poller process, not just one poll cycle's batch. Extracted
# into D2TG::Poller::persist_offset_safe so cli/poller.pl's main loop
# calls a directly unit-testable, non-fatal helper instead.

sub capture_stderr {
    my ($code) = @_;
    my $err = '';
    open my $fh, '>', \$err or die $!;
    my $old = select $fh;
    local *STDERR = $fh;
    $code->();
    select $old;
    close $fh;
    return $err;
}

package Fake::Store::DyingSetOffset;

sub new {
    my ( $class, %args ) = @_;
    return bless { dies => $args{dies}, calls => [] }, $class;
}

sub set_offset {
    my ( $self, $offset, $bot_key ) = @_;
    push @{ $self->{calls} }, [ $offset, $bot_key ];
    die "database is locked\n" if $self->{dies};
    return;
}

package main;

{
    # The failure scenario: set_offset dies (e.g. a locked database).
    # This must not propagate - the caller (cli/poller.pl's persistent
    # main loop) must survive it.
    my $store = Fake::Store::DyingSetOffset->new( dies => 1 );

    my $err;
    my $result;
    my $lived = eval {
        $err = capture_stderr( sub { $result = D2TG::Poller::persist_offset_safe( $store, 42, 'sometoken' ) } );
        1;
    };

    ok( $lived, 'persist_offset_safe does not propagate a set_offset death - the caller survives' );
    like( $err, qr/set_offset/, 'an error mentioning set_offset is logged to STDERR' );
    is_deeply( $store->{calls}, [ [ 42, 'sometoken' ] ], 'set_offset was still called with the correct arguments before it died' );

    # TGT-191 (live production incident: 2 real messages permanently
    # lost): persist_offset_safe used to be void always - the caller
    # had no way to tell a failed persist from a successful one, so it
    # advanced its own in-memory offset unconditionally, which could
    # let a subsequent getUpdates call confirm an unpersisted batch to
    # Telegram (never redelivered again) before a crash. Now returns a
    # false value on failure so the caller can hold the offset back.
    ok( !$result, 'persist_offset_safe returns a false value when set_offset fails (TGT-191)' );
}

{
    # Regression: a successful set_offset behaves exactly as before -
    # called once, with the right arguments, nothing printed.
    my $store = Fake::Store::DyingSetOffset->new( dies => 0 );

    my $result;
    my $err = capture_stderr( sub { $result = D2TG::Poller::persist_offset_safe( $store, 99, 'othertoken' ) } );

    is( $err, '', 'nothing is printed to STDERR when set_offset succeeds' );
    is_deeply( $store->{calls}, [ [ 99, 'othertoken' ] ], 'set_offset is called exactly once with the correct arguments' );
    ok( $result, 'persist_offset_safe returns a true value when set_offset succeeds (TGT-191)' );
}

{
    # Matching cli/poller.pl's own existing "if defined $pair->{offset}"
    # guard: an undef offset must not call set_offset at all.
    my $store = Fake::Store::DyingSetOffset->new( dies => 0 );

    my $result = D2TG::Poller::persist_offset_safe( $store, undef, 'sometoken' );

    is_deeply( $store->{calls}, [], 'set_offset is never called when the offset is undef' );
    ok( $result, 'an undef offset (nothing to persist) is reported as success, not failure (TGT-191)' );
}

done_testing();
