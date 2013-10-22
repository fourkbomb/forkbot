package ForkBot::Plugins::Hugger;
use strict;
use warnings;


sub onUnknownMsg {
	my ($msg, $nick, $ident, $host, $dest, $conn, $irc) = @_;

	my @sadness = (":(", ";_;", ":[", ":<");

	for (@sadness) {
		if ($msg =~ /;_+;/ or $msg =~ /:'?-?\(/ or $msg =~ /:\[/ or $msg =~ /:</) {
			print "SADNESS DETECTED!\n";
			$irc->msg($dest, "SADNESS DETECTED!");
			$irc->msg($dest, "\x01ACTION hugs $nick\x01");
			last;
		}
	}
}

1;
