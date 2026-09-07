use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);

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
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( $out, $rc, undef ) = run_poller();

    is( $rc, 0, 'exits 0 when both env vars are set' );
    like( $out, qr/\S/, 'prints a startup confirmation to STDOUT' );
}

done_testing();
