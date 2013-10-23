#!/usr/bin/perl
use strict;
use warnings;
use threads;
use utf8;
use v5.010;
use Symbol qw(delete_package);
use Time::HiRes qw(alarm);
use IO::Socket::INET;
use Thread::Queue;


our $VERSION = "0.1";
print "== forkbot v$VERSION starting up ==\n";
print "loading prefs...\n";
my %prefs :shared = (
	server		=> 'irc.freenode.net',
	port		=> '6667',
	nick		=> 'forkboto',
	ident		=> 'forkbot',
	timeout		=> 100, # amount of time to wait for any kind of response from the server. PINGs are sent every 50 seconds.
	superu		=> 'forkbomb!.*@.*', # superuser - for eval and friends
	prefix		=> '+',
	threads		=> 10, # number of threads to use - more => faster processing of irc, but higher mem+cpu usage.
	server_pass => "",
	modules		=> "test,Hugger",
	channels    => "##forkbot",
);

my %prefdoc = (
	server		=> "IRC server to connect to",
	port		=> "Port that IRC server is running on",
	nick		=> "Nickname to use",
	ident		=> "ident to use (after the ! in hostmask)",
	timeout 	=> "Time to wait before disconnecting from the server. PINGs are sent every 50 seconds.",
	superu  	=> "User who can run commands like eval, join, etc",
	prefix		=> "Command prefix - like +help or something",
	threads 	=> "Number of threads to use - more => faster processing of IRC input, but higher RAM/CPU usage",
	server_pass	=> "user:pass of server - sent initially, as in /PASS user:pass",
	modules		=> "Modules to load on startup",
	channels	=> "Channels to join after connecting",
);
sub writeConfig {
	print "!! Failed to open config file: $!\n";
	print "!! No config file found. Writing defaults...\n";
	open F, ">", "forkbot.conf" or die "Failed to open config for writing: $!\n";
	for (keys %prefs) {
		print F "# $prefdoc{$_}\n";
		print F "$_=$prefs{$_}\n";
	}
	print "Done. Edit forkbot.conf!\n";
	close F;
	exit;
}

open CONFIG, "<", "forkbot.conf" or &writeConfig;
while (<CONFIG>) {
	next if /^#/;
	chomp;
	my ($k,$v) = split/=/,$_,2;
	$prefs{$k} = $v;
}
close CONFIG;

my @modules :shared = split/, */,$prefs{modules};
my @channels :shared = split/, */,$prefs{channels};
eval "'asdf' =~ /$prefs{superu}/";
if ($@) {
	print STDERR "!! FATAL ERROR IN PREFERENCES !!\n";
	print STDERR "superu regexp is invalid:\n";
	print STDERR $@;
	print STDERR "\nBailing out.\n";
	exit 23;
}




print "initialising connection to: $prefs{server}/$prefs{port}\n";
my $conn = IO::Socket::INET->new(
	PeerAddr => $prefs{server},
	PeerPort => $prefs{port},
	Proto	 => "tcp"
);
for (@modules) {
	my @res = &loadModule($_);
	if ($res[0] == 1) {
		print "!! ERRORS DETECTED IN $_ !!\n";
		print $res[1], "\n";
		print "Waiting five seconds before resuming load...\n";
		sleep 5;
	}
	else {
		print "Successfully loaded $_.\n";
	}
}

our $last_pong_time :shared; 
sub ping {
	# TODO make this configurable (for slow connections)
	# check for how long it's been since the last response from the server.
	my $time = time - $last_pong_time if defined $last_pong_time;
	my $tm = $prefs{timeout};
	if (defined $last_pong_time and $time >= $tm) {
		print STDERR "!! WARNING !!\n",
		"It's been $time seconds since the server sent a response - I may have disconnected. I'm going to restart now...\n";
		close $conn;
		exec $^X, $0, join(" ", @ARGV);
	}
	print "[DEBUG] PING\n";
	print $conn "PING :forkboto\r\n" if defined $conn;
}

print "logging in as $prefs{nick} (ident $prefs{ident})\n";
print $conn "PASS $prefs{server_pass}\r\n" if $prefs{server_pass} ne "";
print $conn "NICK :$prefs{nick}\r\n";
print $conn "USER $prefs{ident} * 8 :forkbot rules\r\n";
print "logged in...\n";

# messages to go to the server
my $res_q = Thread::Queue->new();
# messages coming from the server
my $todo_q= Thread::Queue->new();

threads->create(\&sender)->detach();
threads->create(\&stdinHelper)->detach();

# UNLEASH THE [thread] POOL
my @pool = map {
	threads->create(\&parseLn);
} 1 .. $prefs{threads};

$SIG{"ALRM"} = \&ping;
alarm(50, 50); # ping every 50 seconds
print "Startup finished.\n";
print ">> Receiving MOTD...\n";

print $conn "JOIN $_\r\n" for @channels;

while (<$conn>) {
	chomp;
	#print $_, "\n";
	{
		# grab new stuff from the server
		lock($todo_q);
		$todo_q->enqueue($_);
	}
	

}
sleep 4; # wait for a bit.
sub sender {
	# send stuff that's been buffered.
	while (1) {
		my $el = $res_q->dequeue(); 
		next if not defined $el or $el =~ /^\s*$/;
		print "$el\n";
		print $conn $el, "\r\n";
	}
	
}

sub stdinHelper {
	# send raw IRC commands to the server.
	# TODO make this so people can control the bot from the cli
	while (<STDIN>) {
		chomp;
		{
			lock($res_q);
			$res_q->enqueue($_);
		}
	}
}

sub parseLn {
	while (1) {

		my $line = $todo_q->dequeue();
		if (not defined $line) {
			print STDERR "!! Thread " . threads->tid() . " finished\n";
			last;
		}
		&handleLine($line);
	}
}

sub isSU {
	my $hm = shift;
	return eval "\$hm =~ /$prefs{superu}/";
}

sub reply {
	if ($_[0] eq "*main::main") {
		shift;
	}
	my ($dest, $nick, $msg) = @_;
	{
		lock $res_q;
		$res_q->enqueue("PRIVMSG $dest :$msg");
	}
}

sub msg {
	if ($_[0] eq "*main::main") {
		shift;
	}
	my ($dest, $msg) = @_;
	{
		lock $res_q;
		$res_q->enqueue("PRIVMSG $dest :$msg");
	}
}

sub notice {
	if ($_[0] eq "*main::main") {
		shift;
	}
	my ($dest, $msg) = @_;
	{
		lock $res_q;
		$res_q->enqueue("NOTICE $dest :$msg");
	}
}

sub sendRaw {
	if ($_[0] eq "*main::main") {
		shift;
	}
	{
		lock $res_q;
		$res_q->enqueue(shift);
	}
}

sub parseDigits {
	my ($sender, $what, $dest, $msg) = @_;
	# if necessary, any bot processing will go here.
	my ($nick, $ident, $host) = split/[!@]/,$sender;
	&modMethod('onUnknownServerResponse', $what, $msg, $nick, $ident, $host, $dest, *main, $conn);
}

sub modMethod {
	my $method = shift;
	my @args = @_;
	for (@modules) {
		my $sub = "ForkBot::Plugins::${_}::$method";
		my $ret = eval "$sub(\@args)";
		if (not $@) {
			if ($ret) {
				return 1;
			}
		}
		else {
		}
	}
	return 0;
}

sub handleLine {
	my $line = shift;
	my ($sender, $what, $dest, $msg) = split/ /,$line,4;
	if ($what eq "372") {
		return;
	}
	elsif ($what eq "376") {
		print ">> End of MOTD\n";
		return;
	}
	$sender =~ s/^://;
	$msg =~ s/^:// if defined $msg;
	my @toQueue = qw();

	if ($what eq "PRIVMSG") {
		my ($nick,$ident,$host) = (split/[!@]/, $sender);
		print "$nick said in ". ($dest eq $prefs{nick} ? "PM" : $dest) . ": $msg\n";
		if ($msg =~ /\x01([^\1 ]+)(?: ([^\1]*)|)\x01/) {
			my $d = ($dest eq $prefs{nick} ? $nick : $dest);
			# call onCTCP(ctcp, what, sender, dest)
			# eg: onCTCP("ACTION", "shakes fist", "someone", "#channel")
			&onCTCP($1, $2, $nick, $ident, $host, $d);
			return;
		}
		else {
			$dest = $nick if $dest eq $prefs{nick};
			# more stuff is handled in here.
			&onMsg($msg, $nick, $ident, $host, $dest, $conn, *main);
		}
	}
	elsif ($what =~ /^\d\d\d$/) {
		&parseDigits($sender, $what, $dest, $msg, $conn, *main);
	}

	$last_pong_time = time;
}
sub loadModule {
	my $mpath = shift;
	$mpath = "plugins/$mpath.pm";
	if (-e $mpath) {
		eval "require '$mpath'";
		if ($@) {
			return (1, $@);
		}
		else {
			require $mpath;
			return (0, "Load success!\n");
		}
	}
	else {
		print "\n";
		return (1, "File \"$mpath\" does not exist.");
	}
}

sub unloadModule {
	my $mname = shift;
	my $rn = "ForkBot::Plugins::$mname";
	delete_package($rn);
	delete $INC{"plugins/$mname.pm"};
	@modules = grep { !/^$mname$/ } @modules;
}	


sub onMsg {
	my ($msg, $nick, $ident, $host, $dest) = @_;

	if (&modMethod("onMsg", $msg, $nick, $ident, $host, $dest, $conn, *main) == 1) {
		return;
	}
	if ($msg =~ /^\Q$prefs{prefix}\E/) {
		$msg =~ s/^\Q$prefs{prefix}\E//;
		$msg =~ s/^([^\s]+)//;
		my $cmd = lc $1;
		# check it's a valid function name
		# TODO add a %cmds hash for other function names.
		if ($cmd =~	/ (?[ ( \p{Word} & \p{XID_Start} ) + [_] ]) \p{XID_Continue}* /x) {
			$msg =~ s/^\s+//;
			$msg =~ s/\s+$//;
			$msg =~ s/\s+/ /;
			if (&onCmd($cmd, $msg, $nick, $ident, $host, $dest)) {
				return;
			}
			elsif (&modMethod("cmd_$cmd", $msg, $nick, $ident, $host, $dest, $conn, *main) == 1) {
				return;
			}
		}
		else {
			&notice($nick, "$cmd is an invalid command name.\n");
		}
	}
	elsif ($msg =~ /^\Q$prefs{nick}\E[:,;]? */) {
		$msg =~ s/^\Q$prefs{nick}\E[:,;]? *//;
		$msg =~ s/^\s+//;
		$msg =~ s/^(\w+?) //;
		my $cmd = lc $1;
		if ($cmd =~	/ (?[ ( \p{Word} & \p{XID_Start} ) + [_] ]) \p{XID_Continue}* /x) {
			$msg =~ s/^\s+//;
			$msg =~ s/\s+$//;
			$msg =~ s/\s+/ /;
			if (&onCmd($cmd, $msg, $nick, $ident, $host, $dest)) {
				return;
			}
			elsif (&modMethod("cmd_$cmd", $msg, $nick, $ident, $host, $dest, $conn, *main) == 1) {
				return;
			}
		}
		else {
			&notice($nick, "$cmd is an invalid command name.\n");
		}
	}
	else {
		&modMethod("onUnknownMsg", $msg, $nick, $ident, $host, $dest, $conn, *main);
	}
}

sub onCmd {
	my ($cmd, $msg, $nick, $ident, $host, $dest) = @_;
	print "cmd: $cmd\n";
	my @args = split/ /,$msg;
	given ($cmd) {
		when ("join") {
			print ">> Join $msg ($nick)\n";
			&sendRaw("JOIN $_") for @args;
		}
		when ("leave") {
			print ">> Leave $msg ($nick)\n";
			&sendRaw("PART $_") for @args;
		}
		when (/^load$/) {
			print ">> Load: $args[0]\n";
			&loadModule($args[0]);
		}
		when (/^unload$/) {
			print ">> Unload module: $args[0]\n";
			&unloadModule($args[0]);
		}
		when (/^die/ or /^explode/) {
			print "-- QUIT REQUEST BY $nick in $dest --\n";
			if (/^explode/) {
				&msg($dest, "5... 4... 3... 2... 1... 0!");
				&sendRaw("QUIT :KA-BOOM!");
			}
			else {
				&notice($nick, "Bye now!");
				my @quitmessages = ("*stares at $nick*", "IT'S SAF--", "OH SHI--", "hmm, I wonder what this red button does?", 
					"I *think* this is the right end of the gun", "are you *sure* arsenic is OK to eat?");
				$msg = $quitmessages[int(rand($#quitmessages))];
				&sendRaw("QUIT :$msg");
				&sendRaw("PING :$_") for 1..$prefs{threads};
				sleep 4;
			}
		}
		when (/^p([aeiou])ng/) {
			my %v = (
				a => 'e',
				e => 'i',
				i => 'o',
				o => 'u',
				u => 'a'
			);
			&reply($dest, $nick, "p$v{$1}ng");
		}
		when (/^pref/) {
			$args[0] = lc ($args[0] or "");
			if ($args[0] eq "get") {
				if (exists $prefs{$args[1]}) {
					&reply($dest, $nick, "$args[1] is $prefs{$args[1]}");
				}
				else {
					&reply($dest, $nick, "$args[1] is unset. Set prefs: " . join(', ', keys %prefs));
				}
			}
			elsif ($args[0] eq "set" and $args[1]) {
				$prefs{$args[1]} = ($args[2] or "");
				&reply($dest, $nick, "$args[1] set to '" . ($args[2] or "") . "'.");
			}
			else {
				&notice($dest, "usage: pref <get|set> <pref> [value]");
			}
		}
		when (/^eval/ and &isSU("$nick!$ident\@$host")) {
			print "!! $nick is evalutaing $msg in $dest... !!\n";
			my $r = eval "$msg";
			if ($@) {
				print "!! Error in eval: $@\n";
				$@ =~ s/\n//g;
				&reply($dest, $nick, "Error: $@");
			}
			else {
				&reply($dest, $nick, "Result: $r");
			}
		}
		when (/^say/) {
			my $dest = shift @args;
			&msg($dest, join(" ", @args));
		}
		when (/^raw/) {
			&sendRaw($msg);
		}
		default {
			return 0;
		}
	}
	return 1;
}

END {
	print "Quitting...\n";
	$todo_q->enqueue( (undef) x $prefs{threads} ) if defined $todo_q;
	sleep 2;
	$_->join() for @pool;
}
