use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-279 (own follow-up filed by TGT-278's survey): continuing
# D2TG::Store.pm's decomposition - the sent-reply audit-trail cluster
# (record_sent_text/record_sent_voice/text_only_replies/
# is_recent_duplicate_reply, all of which only need the shared $dbh)
# moved into a new D2TG::Store::SentReplyAudit module, mirroring
# D2TG::Store::RetryQueue/History/AccessControl's own established
# DBI-handle-wrapper precedent.

require D2TG::Store;
require D2TG::Store::SentReplyAudit;

for my $name (qw(record_sent_text record_sent_voice text_only_replies is_recent_duplicate_reply)) {
    ok( D2TG::Store::SentReplyAudit->can($name), "D2TG::Store::SentReplyAudit owns $name" );
}

done_testing();
