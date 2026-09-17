use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Find;
use Pod::Checker;

# TGT-277 (found via a scheduled podchecker sweep during TGT-276's own
# documentation work): several lib/**/*.pod files have unresolved
# internal L<name> links whose target =head2 anchor includes a full
# signature (e.g. "=head2 extract_bot_flag(@args)") while the link only
# names the bare function ("L</extract_bot_flag>") - Pod::Checker
# requires an exact match. No structural test existed to catch this
# drift; this one runs Pod::Checker's own Perl API (not the podchecker
# binary, so it works identically in and out of Docker) against every
# .pod file in lib/ and asserts zero errors.

my $lib_dir = "$Bin/../lib";
my @pod_files;
find( { wanted => sub { push @pod_files, $File::Find::name if /\.pod$/ }, no_chdir => 1 }, $lib_dir );

ok( scalar(@pod_files) > 0, 'found at least one .pod file under lib/' );

for my $file ( sort @pod_files ) {
    my $checker = Pod::Checker->new( -quiet => 1 );
    my $out;
    open my $fh, '>', \$out or die $!;
    $checker->parse_from_file( $file, $fh );
    close $fh;

    is( $checker->num_errors, 0, "$file has zero podchecker errors" );
}

done_testing();
