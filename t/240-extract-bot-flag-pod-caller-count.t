use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-240 (found via a scheduled JOB-005 doc-accuracy hunt): the POD
# for D2TG::Reply::Args::extract_bot_flag_or_die (and docs/commands.md's own
# copy of the same sentence) named "7 cli/*.pl scripts" and listed 7
# names - stale since TGT-237 added cli/retry-transcription.pl as an
# 8th real caller. Matching t/98-skills-md-cli-list-current.t's own
# established pattern (guard a hardcoded prose count/list against the
# real file list so a future ticket adding a caller fails the suite
# instead of silently letting this drift again).

my $lib_dir  = File::Spec->catdir( $Bin, '..', 'lib' );
my $cli_dir  = File::Spec->catdir( $Bin, '..', 'cli' );

# TGT-265: this POD moved from D2TG/Reply.pm into D2TG/Reply/Args.pod
# (extract_bot_flag_or_die's own new home) when the CLI argv-parsing
# cluster was extracted out of D2TG::Reply.
my $pod_file = File::Spec->catfile( $lib_dir, 'D2TG', 'Reply', 'Args.pod' );

# The real, current set of cli/*.pl scripts that actually call
# extract_bot_flag_or_die - the ground truth this POD must match.
opendir my $dh, $cli_dir or die $!;
my @real_callers;
for my $file ( sort readdir $dh ) {
    next unless $file =~ /\.pl$/;
    my $path = File::Spec->catfile( $cli_dir, $file );
    open my $fh, '<', $path or die $!;
    local $/;
    my $content = <$fh>;
    push @real_callers, $file if $content =~ /extract_bot_flag_or_die/;
}
closedir $dh;

ok( scalar(@real_callers) > 0, 'sanity: at least one real cli/*.pl caller was found by the grep-equivalent scan' );

open my $pod_fh, '<', $pod_file or die $!;
local $/;
my $pod_text = <$pod_fh>;
close $pod_fh;

# Extract the POD's own stated count and the parenthetical caller list
# from its =head2 extract_bot_flag_or_die section.
my ($pod_section) = $pod_text =~ /(=head2 extract_bot_flag_or_die.*?)(?==head2|\z)/s;
ok( $pod_section, 'the extract_bot_flag_or_die POD section exists' );

my ($stated_count) = $pod_section =~ /centralizes.*?idiom that (\d+)\s*C<cli/s;
is( $stated_count, scalar(@real_callers), "the POD states the same count ($stated_count) as the real number of callers (" . scalar(@real_callers) . ")" );

for my $file (@real_callers) {
    my ($basename) = $file =~ /^(.*)\.pl$/;
    like( $pod_section, qr/C<\Q$basename\E>/, "the POD's own caller list names $file" );
}

done_testing();
