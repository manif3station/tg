use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# TGT-250 (Michael, live via Telegram msg #443, 2026-09-15): "You don't
# need to mention that. To me, that is noise and confusion to the
# agent. Stop printing that note" - referring to the different_token
# branch's NOTE in cli/poller.pl, which fires every poll cycle a
# different-bot-token sibling poller is detected (the routine
# multi-project-on-one-host case, confirmed benign by the note's own
# wording). The same_token and unknown_token WARNING branches stay
# unchanged - those remain genuinely actionable.

open my $fh, '<', "$Bin/../cli/poller.pl" or die $!;
local $/;
my $source = <$fh>;
close $fh;

unlike( $source, qr/other poller-shaped process\(es\) detected/,
    'the different-token NOTE text no longer appears anywhere in cli/poller.pl' );

my ($different_block) = $source =~ /if \s*\(\@different_token\)\s*\{(.*?)\n    \}/xs;
if ( defined $different_block ) {
    unlike( $different_block, qr/print\s+STDERR/,
        'the different_token branch (if it still exists) prints nothing' );
}
else {
    pass( 'the different_token branch/print has been removed entirely' );
}

# same_token and unknown_token branches must be untouched.
my ($same_block) = $source =~ /if \s*\(\@same_token\)\s*\{(.*?)\n    \}/xs;
ok( defined $same_block, 'found the same_token warning block in cli/poller.pl' );
like( $same_block, qr/print\s+STDERR/,        'the same_token branch still prints' );
like( $same_block, qr/possible orphaned poller instance/, 'the same_token WARNING text is unchanged' );

my ($unknown_block) = $source =~ /if \s*\(\@unknown_token\)\s*\{(.*?)\n    \}/xs;
ok( defined $unknown_block, 'found the unknown_token warning block in cli/poller.pl' );
like( $unknown_block, qr/print\s+STDERR/,        'the unknown_token branch still prints' );
like( $unknown_block, qr/possible orphaned poller instance/, 'the unknown_token WARNING text is unchanged' );

done_testing();
