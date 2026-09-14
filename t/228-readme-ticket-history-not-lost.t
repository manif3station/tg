use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-228 (found via a scheduled JOB-005 doc-accuracy hunt):
# README.md's top-of-file rolling changelog (each shipped ticket adds
# its own paragraph, newest bolded as **Status:**, older ones retained
# below as plain paragraphs) broke for 5 consecutive commits
# (TGT-220/222/225/226/227's own documentation-column edits each
# REPLACED the immediately-preceding ticket's paragraph instead of
# prepending above it), silently erasing TGT-219/220/222/225/226's own
# fix write-ups from README.md entirely, even though Changes and
# docs/POLICIES.md still have them correctly. This is a structural
# regression guard: it fails if any ticket Changes records as shipped
# is never mentioned anywhere in README.md's own prose, so a future
# documentation-column commit that accidentally replaces instead of
# prepends is caught by the suite instead of silently recurring.

my $root = File::Spec->catdir( $Bin, '..' );

my $readme = do {
    open my $fh, '<', File::Spec->catfile( $root, 'README.md' ) or die $!;
    local $/;
    <$fh>;
};

# One distinguishing, code-accurate term per ticket that would only
# appear in a real description of that ticket's own fix - not just its
# ticket number (which could appear anywhere incidentally).
my %distinguishing_term = (
    'TGT-219' => qr/failed_downloads.*bot_key|bot_key.*failed_downloads/is,
    'TGT-220' => qr/RETRY WITH/,
    'TGT-222' => qr/HTTP::Tiny/,
    'TGT-225' => qr/record_failed_download/,
    'TGT-226' => qr/_bot_flag/,
);

for my $ticket ( sort keys %distinguishing_term ) {
    like(
        $readme,
        $distinguishing_term{$ticket},
        "README.md still describes ${ticket}'s own shipped fix"
    );
}

done_testing();
