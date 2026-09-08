use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Config;

# TGT-094 (live production incident): the poller's own version-change
# self-restart used to exec() the literal $0 path captured at process
# launch. If an install renames the running poller's own cli/*.pl file
# (as TGT-093 just did for real), that cached path no longer exists on
# disk and the restart exec() dies instead of succeeding.
#
# Fix: resolve_self_exec_path re-checks, at restart time, whether the
# known current basename (poller.pl) exists in the script's own bin
# directory - which stays valid even if the file was renamed since
# launch, because only the filename changed, not the directory. Falls
# back to the original $0 only if that lookup fails.

{
    my $bin_dir = tempdir( CLEANUP => 1 );
    my $current = File::Spec->catfile( $bin_dir, 'poller.pl' );
    open my $fh, '>', $current or die $!;
    print {$fh} "#!/usr/bin/env perl\n";
    close $fh;

    my $fallback = File::Spec->catfile( $bin_dir, 'poller' );    # stale, pre-rename path

    my $resolved = D2TG::Config::resolve_self_exec_path(
        bin_dir  => $bin_dir,
        basename => 'poller.pl',
        fallback => $fallback,
    );

    is( $resolved, $current, 'resolves to the current on-disk entrypoint, not the stale fallback, when it exists (TGT-094)' );
}

{
    my $bin_dir  = tempdir( CLEANUP => 1 );
    my $fallback = File::Spec->catfile( $bin_dir, 'poller' );
    open my $fh, '>', $fallback or die $!;
    print {$fh} "#!/usr/bin/env perl\n";
    close $fh;

    my $resolved = D2TG::Config::resolve_self_exec_path(
        bin_dir  => $bin_dir,
        basename => 'poller.pl',
        fallback => $fallback,
    );

    is( $resolved, $fallback, 'falls back to the given path when the expected current basename does not exist' );
}

done_testing();
