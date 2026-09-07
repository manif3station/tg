use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $poller = File::Spec->catfile( $Bin, '..', 'cli', 'poller' );

{
    local %ENV = %ENV;
    delete $ENV{D2TG_CHAT_ID};
    $ENV{D2TG_TOKEN} = 'test-token';

    my $out = `$poller 2>/tmp/d2tg-poller-stderr.$$`;
    my $rc  = $? >> 8;
    open my $fh, '<', "/tmp/d2tg-poller-stderr.$$" or die $!;
    my $err = do { local $/; <$fh> };
    close $fh;
    unlink "/tmp/d2tg-poller-stderr.$$";

    isnt( $rc, 0, 'exits non-zero when D2TG_CHAT_ID is unset' );
    is( $out, '', 'nothing printed to STDOUT when the guard fails' );
    like( $err, qr/D2TG_CHAT_ID/, 'STDERR names the missing var' );
}

{
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $out = `$poller 2>/dev/null`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'exits 0 when both env vars are set' );
    like( $out, qr/\S/, 'prints a startup confirmation to STDOUT' );
}

done_testing();
