use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->catdir( $Bin, '..' );

for my $dir (qw(lib/D2TG cli t tickets)) {
    ok( -d File::Spec->catdir( $root, split m{/}, $dir ), "$dir/ exists" );
}

for my $file (qw(README.md Changes LICENSE .env)) {
    ok( -f File::Spec->catfile( $root, $file ), "$file exists" );
}

open my $fh, '<', File::Spec->catfile( $root, '.env' ) or die $!;
my $env = do { local $/; <$fh> };
close $fh;
like( $env, qr/^VERSION=0\.49$/m, '.env carries VERSION=0.49' );

done_testing();
