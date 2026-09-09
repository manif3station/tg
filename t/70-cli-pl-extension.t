use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $cli_dir = File::Spec->catdir( $Bin, '..', 'cli' );

my @commands = qw(approve help history poller reply retry-download send status text-only-replies unread);

for my $name (@commands) {
    my $pl_path  = File::Spec->catfile( $cli_dir, "$name.pl" );
    my $bare_path = File::Spec->catfile( $cli_dir, $name );

    ok( -f $pl_path, "cli/$name.pl exists (TGT-093)" );
    ok( -x $pl_path, "cli/$name.pl is executable" ) if -f $pl_path;
    ok( !-e $bare_path, "cli/$name (bare, no extension) no longer exists" );
}

# Every renamed script must still be valid, runnable Perl.
for my $name (@commands) {
    my $pl_path = File::Spec->catfile( $cli_dir, "$name.pl" );
    next unless -f $pl_path;

    my $output = `"$^X" -c "$pl_path" 2>&1`;
    like( $output, qr/syntax OK/, "cli/$name.pl compiles cleanly" );
}

done_testing();
