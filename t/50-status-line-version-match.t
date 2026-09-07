use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->catdir( $Bin, '..' );

open my $efh, '<', File::Spec->catfile( $root, '.env' ) or die $!;
my $env = do { local $/; <$efh> };
close $efh;

my ($version) = $env =~ /^VERSION=(\S+)$/m;
ok( defined $version, '.env has a VERSION' );

for my $file (qw(README.md SKILLS.md)) {
    open my $fh, '<', File::Spec->catfile( $root, $file ) or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;

    like(
        $content,
        qr/Status: early implementation \(v\Q$version\E\)/,
        "${file} Status line names the current .env version ($version)"
    );
}

done_testing();
