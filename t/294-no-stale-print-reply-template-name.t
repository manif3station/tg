use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-294 (found via a user-requested comprehensive bug/improvement
# sweep): docs/commands.md and lib/D2TG/Poller.pod both referred to
# D2TG::Poller::_print_reply_template as the poller's REPLY WITH
# template function. That function was renamed and relocated during
# the TGT-259/TGT-276 decomposition; it is now
# D2TG::Poller::Format::print_reply_template (no leading underscore,
# different package). The same stale name also appeared in 3 comments
# inside currently-passing tests (t/217, t/220, t/226) - not
# user-facing, but the same drift. docs/POLICIES.md's own historical
# write-ups (which describe what was true AT THE TIME of each past
# ticket) are deliberately excluded - rewriting history there would
# make the changelog inaccurate, not more correct.

my @files = (
    File::Spec->catfile( $Bin, '..', 'docs',                    'commands.md' ),
    File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Poller.pod' ),
    File::Spec->catfile( $Bin, '217-edited-message-reply-template.t' ),
    File::Spec->catfile( $Bin, '220-media-failed-retry-with-bot-flag.t' ),
    File::Spec->catfile( $Bin, '226-bot-flag-helper-extracted.t' ),
);

for my $file (@files) {
    open my $fh, '<', $file or die "can't read $file: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    unlike( $source, qr/_print_reply_template/,
        "$file: no stale reference to the pre-TGT-259/276 name _print_reply_template" );
}

done_testing();
