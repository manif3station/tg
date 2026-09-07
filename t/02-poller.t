use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);
use IPC::Open3;
use Symbol qw(gensym);
use POSIX qw(:sys_wait_h);

my $poller = File::Spec->catfile( $Bin, '..', 'cli', 'poller' );

sub run_poller {
    my ( $stderr_fh, $stderr_file ) = tempfile( UNLINK => 1 );
    close $stderr_fh;

    open( local *OLDERR, '>&', \*STDERR ) or die "dup STDERR: $!";
    open( STDERR, '>', $stderr_file )     or die "redirect STDERR: $!";

    open my $out_fh, '-|', $poller or die "run poller: $!";
    my $out = do { local $/; <$out_fh> };
    close $out_fh;
    my $rc = $? >> 8;

    open( STDERR, '>&', \*OLDERR ) or die "restore STDERR: $!";

    open my $fh, '<', $stderr_file or die $!;
    my $err = do { local $/; <$fh> };
    close $fh;

    return ( $out, $rc, $err );
}

for my $missing_value ( undef, '' ) {
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN} = 'test-token';
    if ( defined $missing_value ) {
        $ENV{D2TG_CHAT_ID} = $missing_value;
    }
    else {
        delete $ENV{D2TG_CHAT_ID};
    }

    my $label = defined $missing_value ? 'empty string' : 'unset';
    my ( $out, $rc, $err ) = run_poller();

    isnt( $rc, 0, "exits non-zero when D2TG_CHAT_ID is $label" );
    is( $out, '', "nothing printed to STDOUT when D2TG_CHAT_ID is $label" );
    like( $err, qr/D2TG_CHAT_ID/, "STDERR names the missing var ($label)" );
}

{
    # Since TGT-005, once the guard passes cli/poller enters a real
    # long-poll loop and never exits on its own - it is a long-running
    # service now, not a one-shot script. This test only proves the guard
    # passed and the confirmation line printed BEFORE any network call is
    # made, then kills the process outright; it never waits on the loop
    # and never talks to the real Telegram API, per this project's
    # no-real-network-in-tests rule. Loop correctness itself is
    # unit-tested in t/04-poller-loop.t via D2TG::Poller::run_once against
    # a mocked client.
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( $child_out, $child_err ) = ( gensym, gensym );
    my $pid = open3( my $in, $child_out, $child_err, $poller );

    my $first_line = <$child_out>;

    kill 'KILL', $pid;
    waitpid( $pid, 0 );

    like( $first_line, qr/\S/, 'prints a startup confirmation to STDOUT before polling' );

    close $_ for grep { defined } ( $in, $child_out, $child_err );
}

done_testing();
