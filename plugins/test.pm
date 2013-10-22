package ForkBot::Plugins::test;


sub cmd_test {
	print join(", ", @_);
	my ($msg, $nick, $ident, $host, $dest, $conn, $main) = @_;
	print "ya, it works!\n";
	$main->msg($dest, "This is a test!");
	return 1;
}

1;
