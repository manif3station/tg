use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->catdir( $Bin, '..' );

opendir my $dh, File::Spec->catdir( $root, 'cli' ) or die $!;
my @real_files = sort grep { /\.pl$/ } readdir $dh;
closedir $dh;

open my $fh, '<', File::Spec->catfile( $root, 'SKILLS.md' ) or die $!;
my $skills_md = do { local $/; <$fh> };
close $fh;

# TGT-130: this test exists specifically to prevent the doc-drift class
# TGT-123 already fixed once (SKILLS.md's cli/*.pl list falling behind
# as new entrypoints are added) from recurring silently a third time.
#
# A QA-stage Codex review caught that scanning the whole file for any
# `cli/*.pl`-shaped reference doesn't actually verify the DESIGNATED
# list is current - a filename could be removed from the list itself
# but survive in nearby explanatory prose (as this very sentence's own
# TGT-130 note does, naming cli/tts.pl a second time) and the test would
# still pass. Scoped to just that one parenthetical instead, so only the
# canonical list itself is checked.
my ($list_section) = $skills_md =~
  /Every `cli\/\*` entrypoint file carries a `\.pl` extension internally\s*\((.*?)\)\./s;
die "D2TG test setup: could not find the cli/*.pl list section in SKILLS.md\n"
  unless defined $list_section;

my @documented = grep { !/\*/ } $list_section =~ /`(cli\/[^`\/]+\.pl)`/g;
my %documented = map { my ($base) = m{cli/(.+)}; $base => 1 } @documented;

for my $file (@real_files) {
    ok( $documented{$file}, "SKILLS.md's cli/*.pl list names $file" );
}

is( scalar(@real_files), scalar( keys %documented ),
    'SKILLS.md documents exactly as many cli/*.pl entrypoints as actually exist' );

done_testing();
