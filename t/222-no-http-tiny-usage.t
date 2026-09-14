use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-222: cpan-audit flags 2 CVEs against HTTP::Tiny (CRLF injection,
# cross-origin credential forwarding on redirect). Investigation
# confirmed HTTP::Tiny is a core Perl module never directly invoked by
# this codebase's own runtime code - every HTTP call goes through
# LWP::UserAgent (D2TG::Telegram, D2TG::Download). This is a structural
# regression guard, not a fix for an existing bug: it fails if a future
# change introduces a direct HTTP::Tiny call, which would reopen the
# exploitability question this ticket's own investigation just closed.
#
# Checks actual code usage (a "use"/require statement or a method call
# on the package), not mere text mentions - D2TG::Telegram's own POD
# names HTTP::Tiny by name specifically to document that it is NOT
# used, which a bare text search would misflag as a violation.

my $lib_dir = File::Spec->catdir( $Bin, '..', 'lib', 'D2TG' );
opendir my $dh, $lib_dir or die "can't open $lib_dir: $!";
my @modules = grep { /\.pm$/ } readdir $dh;
closedir $dh;

for my $module (@modules) {
    my $path = File::Spec->catfile( $lib_dir, $module );
    open my $fh, '<', $path or die "can't open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    unlike(
        $content,
        qr/^\s*(?:use|require)\s+HTTP::Tiny\b|HTTP::Tiny\s*->/m,
        "$module does not use HTTP::Tiny in code"
    );
}

done_testing();
