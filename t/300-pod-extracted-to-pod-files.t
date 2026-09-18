use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-300 (found via a user-requested comprehensive bug/improvement
# sweep): 6 modules never had their embedded POD extracted to a
# separate .pod file, breaking the pattern applied to every other
# module in the codebase (docs/POLICIES.md's TGT-273/278/279/280/287
# write-ups). None are over the 500-line cap - this is a
# documentation-consistency fix, not urgency-driven, with zero
# functional code change (t/277-podchecker-clean.t and the full suite
# both stay green).

my @modules = (
    'D2TG/Download.pm',
    'D2TG/Lock.pm',
    'D2TG/Subprocess.pm',
    'D2TG/TTS.pm',
    'D2TG/Poller/Format.pm',
    'D2TG/Store/RetryQueue.pm',
);

for my $module (@modules) {
    my $pm_path  = File::Spec->catfile( $Bin, '..', 'lib', split( '/', $module ) );
    ( my $pod_module = $module ) =~ s/\.pm$/.pod/;
    my $pod_path = File::Spec->catfile( $Bin, '..', 'lib', split( '/', $pod_module ) );

    open my $pm_fh, '<', $pm_path or die "can't read $pm_path: $!";
    local $/;
    my $pm_source = <$pm_fh>;
    close $pm_fh;

    unlike( $pm_source, qr/^=head1/m, "$module has no embedded POD left in the .pm file" );
    ok( -e $pod_path, "$pod_module exists" );
}

done_testing();
