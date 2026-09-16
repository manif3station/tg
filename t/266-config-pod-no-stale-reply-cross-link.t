use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Find;

# TGT-266 (found via a scheduled JOB-005 doc-accuracy hunt): TGT-265
# moved parse_cli_args/extract_bot_flag/extract_bot_flag_or_die out of
# D2TG::Reply into D2TG::Reply::Args, and TGT-263 moved
# retry_failed_transcription/auto_retry_failed_transcriptions out of
# D2TG::Transcribe into D2TG::Transcribe::Retry - both tickets updated
# docs/commands.md and the moved-into/out-of modules' own POD, but
# missed one incoming cross-reference: lib/D2TG/Config.pm's own
# extract_db_flag POD still linked to the pre-move
# C<D2TG::Reply::parse_cli_args> location. This is a structural
# regression test, not just this one fix - it sweeps every live (non
# doc/) .pm/.pod/.pl file for the whole class of stale reference, so a
# future module move that misses an incoming cross-reference fails the
# suite instead of silently drifting again.

my $lib_dir = File::Spec->catdir( $Bin, '..', 'lib' );
my $cli_dir = File::Spec->catdir( $Bin, '..', 'cli' );

my @stale_patterns = (
    qr/D2TG::Reply::extract_bot_flag_or_die\b/,
    qr/D2TG::Reply::extract_bot_flag\b(?!::)/,
    qr/D2TG::Reply::parse_cli_args\b/,
    qr/D2TG::Transcribe::retry_failed_transcription\b/,
    qr/D2TG::Transcribe::auto_retry_failed_transcriptions\b/,
);

my @files;
for my $dir ( $lib_dir, $cli_dir ) {
    find( sub {
        return unless -f $_;
        return unless /\.(pm|pod|pl)$/;
        push @files, $File::Find::name;
    }, $dir );
}

ok( scalar(@files) > 10, 'sanity: the lib/cli sweep found a reasonable number of files' );

for my $file ( sort @files ) {
    open my $fh, '<', $file or die $!;
    local $/;
    my $content = <$fh>;
    close $fh;

    for my $pattern (@stale_patterns) {
        unlike( $content, $pattern, "$file carries no stale cross-reference matching $pattern" );
    }
}

done_testing();
