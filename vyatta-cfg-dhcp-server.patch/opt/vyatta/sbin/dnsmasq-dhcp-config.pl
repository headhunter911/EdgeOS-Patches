#!/usr/bin/perl

#dnsmasq-dhcp-config.pl 
#v0.1

use strict;
use lib "/opt/vyatta/share/perl5/";

use Getopt::Long;
use NetAddr::IP;

#config
my $config_path = "/etc/dnsmasq.d/dnsmasq-dhcp-config.conf";
my $init_script = "/etc/init.d/dnsmasq";


my $config_out = '';

my $dnsmasq_version = `/usr/sbin/dnsmasq --help | grep dhcp-ttl`;
my $min_lease_time = -1;
my $authoritative = 0;
my $at_least_one_domain = 0;

my @intfs = get_interfaces(); # interfaces that have IPv4 addresses

my %custom_options;

use Vyatta::Config;
my $c = new Vyatta::Config();

$c->setLevel('');
my $router_domain = $c->returnValue('system domain-name');

# listen-on interfaces
my @tmp = $c->returnValues('service dns forwarding listen-on');
my %listen_intfs;
my $num_listen_intfs = scalar(@tmp);
foreach my $tmp (@tmp) {
	$listen_intfs{$tmp} = 1;
}

# execpt-interfaces
my @tmp = $c->returnValues('service dns forwarding except-interface');
my $num_except_intfs = scalar(@tmp);

my $g_serv = $c->exists('service dhcp-server');
my $g_use_dm = $c->returnValue('service dhcp-server use-dnsmasq');
my $g_disabled = $c->returnValue('service dhcp-server disabled');
my $g_dm_dhcp = ($g_serv && (defined($g_use_dm) && $g_use_dm eq 'enable')
                 && (!defined($g_disabled) || $g_disabled eq 'false'));

# 'listen-on' and 'except-interface' are exclusive. They cannot be used
# at the same time.
my $g_dm_fwd = ($num_listen_intfs > 0 || $num_except_intfs > 0);

if ($g_dm_dhcp) {
    parse_config();
}
open(my $fh, '>', $config_path) || die "Couldn't open $config_path - $!";
print $fh $config_out;
close $fh;
#print $config_out;

system("$init_script stop >/dev/null 2>&1");

if ($g_dm_dhcp || $g_dm_fwd) {
    system("$init_script start >/dev/null 2>&1");
}

sub parse_config() {
    $config_out  = "#\n# autogenerated by $0 on " . `date` . "#\n";
#   $config_out .= "dhcp-leasefile=/var/run/dnsmasq-dhcp.leases\n";
    $config_out .= "dhcp-lease-max=1000000\n";
    $config_out .= "dhcp-ignore-names=tag:blockedhosts\n";
    $config_out .= "dhcp-host=isatap,set:blockedhosts\n";
    $config_out .= "dhcp-host=unifi,set:blockedhosts\n";
    $config_out .= "dhcp-host=wpad,set:blockedhosts\n";
	
    if ($router_domain) {
        $config_out .= "domain=$router_domain\n";
    }

	$c->setLevel('service dhcp-server');

        my $staticlease = $c->returnValue("lease-persist");
        if ( $staticlease == "enable" ){
               $config_out .="dhcp-leasefile=/config/dnsmasq-dhcp.leases\n";
        } else{
               $config_out .="dhcp-leasefile=/var/run/dnsmasq-dhcp.leases\n";
        }

	my @global_params = $c->returnValues("global-parameters");
	if ( @global_params > 0 ) {
		$config_out .=
			"# The following "
		  . scalar @global_params
		  . " lines were added as global-parameters in the CLI and \n"
		  . "# have not been validated\n";
		foreach my $line (@global_params) {
			my $decoded_line = replace_quot($line);
			parse_custom_option_code($decoded_line);
			$config_out .= "#$decoded_line\n";
		}
		$config_out .= "\n";
	}
	parse_shared_networks();
	
	$config_out .= "\n#global settings depending on previous config\n";
	if ($min_lease_time != -1) {
		use integer;
		$min_lease_time = $min_lease_time / 2;
		$config_out .= "dhcp-ttl=$min_lease_time\t#this is half the smallest lease time found\n";
	}
	if ($router_domain) {
		$config_out .= "dhcp-fqdn\t#we have default domain, so we can use dhcp-fqdn\n";
	}
	if ($authoritative) {
		$config_out .= "dhcp-authoritative\t#at least one shared-network was declared authoritative\n";
	}
}

sub parse_shared_networks() {
	$c->setLevel('service dhcp-server');
	my @shared_networks = $c->listNodes("shared-network-name");
	if (@shared_networks == 0) {
		raise_error("no shared-network-name defined - need at least one to run dhcp", 1);
	}
	my $found_subnet = 0;
	foreach my $shared_network (@shared_networks) {
		$config_out .= "\n\n###shared-network $shared_network\n";
		$c->setLevel("service dhcp-server shared-network-name $shared_network");
		if ($c->exists("disable")) {
			$config_out .= "#this shared network is disabled";
			next;
		}
		
		#dnsmasq cannot be be authoritative per subnet, only globally on or off.
		if ($c->returnValue("authoritative") eq "enable") {
			$authoritative = 1;
		}
		my @global_params = $c->returnValues("shared-network-parameters");
		if ( @global_params > 0 ) {
			$config_out .=
				"\t# The following "
			  . scalar @global_params
			  . " lines were added as shared-network-parameters in the CLI and \n"
			  . "\t# have not been validated\n";
			foreach my $line (@global_params) {
				my $decoded_line = replace_quot($line);
				$config_out .= "\t#$decoded_line\n";
				my $tmp = parse_custom_options($decoded_line, $shared_network);
				if ($tmp) {
					$config_out .= "\t$tmp";
				}
			}
			$config_out .= "\n";
		}
		
		foreach my $subnet ($c->listNodes("subnet")) {
			$found_subnet = 1;
			parse_subnet($shared_network, $subnet);
		}
		$config_out .= "\n\n###end of shared-network $shared_network\n";
	}
	if (!$found_subnet) {
		raise_error("found no active subnet in any shared-network - need at least one to run dhcp", 1);
	}
}

sub parse_subnet {
	my ($shared_network, $subnet) = @_;
	my $ipobj = new NetAddr::IP("$subnet");
	my $netmask = $ipobj->mask();
	$c->setLevel("service dhcp-server shared-network-name $shared_network subnet $subnet");
	
	$shared_network =~ s/[^A-Za-z0-9]//g;
	$config_out .= "\n\t#subnet $subnet\n";
	
	#check if dnsmasq is listening on the interface matching the subnet
	if ($num_listen_intfs) {
		my $found_intf = 0;
		foreach my $intf (@intfs) {
			if ($intf->{ip}->contains($ipobj)) {
				$found_intf = 1;
				if (!exists($listen_intfs{$intf->{intf}})) {
					raise_error("[Warning] DHCP subnet $subnet is configured on interface " . $intf->{intf} . ",\n"
					. "but this is not configured under service dns forwarding listen-on.\n"
					. "Configuring dnsmasq so that it will also listen on this interface\n", 0);
					$config_out .= "\t\tinterface=" . $intf->{intf} . "\t#automatically added for this dhcp subnet to work\n";
				}
				last;
			}
		}
		if (!$found_intf) {
			raise_error("[Warning] There is no interface that contains subnet $subnet.\n"
			. "DHCP for this subnet can only work if there is a DHCP relay \n"
			. "installed and configured somewhere\n", 0);
		}
	}
	
	my $domain_name = $c->returnValue('domain-name');
	
	my $lease = $c->returnValue('lease');
	my @starts = $c->listNodes('start');
	my @static_mappings = $c->listNodes('static-mapping');
	my @static_ips = ();
	if (@starts == 0 && @static_mappings == 0) {
		raise_error("at least one dhcp range or a static mapping must be defined for dhcp subnet $subnet", 1);
	}
	my $static_mappings_out = "\n\t\t#static reservations for subnet $subnet\n";
	my $static_domain = $domain_name || $router_domain;
	foreach my $static_mapping (@static_mappings) {
		my $ipaddr = $c->returnValue("static-mapping $static_mapping ip-address");
		my $macaddr = $c->returnValue("static-mapping $static_mapping mac-address");
		$static_mappings_out .= "\t\tdhcp-host=$macaddr,set:$shared_network,$ipaddr\t#$static_mapping\n";
		if ($static_domain) {
			if ($dnsmasq_version && $lease =~ /^\d+$/) {
				$ipaddr .= "," . $lease;
			}
			$static_mappings_out .= "\t\thost-record=$static_mapping.$static_domain,$ipaddr\t#$static_mapping.$static_domain\n";
		}
		push(@static_ips, $ipaddr);
	}
	if ($lease) {
		$min_lease_time = ($min_lease_time < $lease && $min_lease_time != -1 ? $min_lease_time : $lease);
		$lease = ",$lease";
	} else {
		$lease='';
	}
	if (@starts == 0) {
		my $first = $ipobj->first()->addr();
		$config_out .= "\t\tdhcp-range=set:$shared_network,$first,static,$netmask$lease\n";
	}
	else {
		my @ranges = handle_excludes(\@starts, \@static_ips);
		foreach my $range (@ranges) {
			$config_out .= "\t\tdhcp-range=set:$shared_network," . $range->{start} . "," . $range->{stop} . ",$netmask$lease\n";
		}
	}
	if ($c->exists('static-route')) {
		my $target_subnet = new NetAddr::IP($c->returnValue("static-route destination-subnet"));
		my $target_router = $c->returnValue("static-route router");
		my $static_route_line = $target_subnet->addr() . "/" . $target_subnet->masklen() . ",$target_router";
		$config_out .= "\t\tdhcp-option=tag:$shared_network,option:classless-static-route,$static_route_line\n";
		$config_out .= "\t\tdhcp-option=tag:$shared_network,254,$static_route_line\n";
	}
	if ($c->exists('unifi-controller')) {
		$config_out .= "\t\tdhcp-option=tag:$shared_network,vendor:ubnt,1," . $c->returnValue('unifi-controller') . "\n";
	}
	if ($domain_name ne '') {
        # ',local' in 'domain=' sets up --local declarations for forward and reverse DNS,
        # but is only valid with /8, /16 or /24 networks.
        if ($netmask eq '255.0.0.0' || $netmask eq '255.255.0.0' || $netmask eq '255.255.255.0') {
            $config_out .= "\t\tdomain=$domain_name,$subnet,local\n";
        } else {
            $config_out .= "\t\tdomain=$domain_name,$subnet\n";
        }
		$at_least_one_domain = 1;
	}

	if ($c->exists('bootfile-name')) {
		my $bootfile_server = $c->returnValue('bootfile-server');
		if ($bootfile_server) {
			if ($bootfile_server =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
				$bootfile_server = ",pxeserver,$bootfile_server";
			}
			else {
				$bootfile_server = ",$bootfile_server";
			}
		}
		else {
			$bootfile_server = '';
		}
		$config_out .= "\t\tdhcp-boot=" . $c->returnValue('bootfile-name') . $bootfile_server . "\n" ;
	}
	my $client_prefix_length = $c->returnValue('client-prefix-length');
	if ($client_prefix_length) {
		my $ip = new NetAddr::IP("255.255.255.255/$client_prefix_length");
		$config_out .= "\t\tdhcp-option=tag:$shared_network,option:netmask," . $ip->network()->addr() . "\n";
	}
	
	my %dhcp_single_options = (
		'default-router' => 'option:router',
		'domain-name' => 'option:domain-name',
		'ip-forwarding' => 'option:ip-forward-enable',
		'bootfile-name' => 'option:bootfile-name',
		'server-identifier' => '54',
		'wpad-url' => '252',
		'tftp-server-name' => 'option:tftp-server',
		'time-offset' => 'option:time-offset',
	);
	while (my($k, $v) = each %dhcp_single_options) {
		if ($c->exists($k)) {
			$config_out .= "\t\tdhcp-option=tag:$shared_network,$v," . $c->returnValue($k) . "\n";
		}
	}
	my %dhcp_multi_options = (
		'dns-server', => 'option:dns-server',
		'ntp-server' => 'option:ntp-server',
		'smtp-server' => 'option:smtp-server',
		'wins-server' => 'option:netbios-ns',
		'pop-server' => 'option:pop3-server',
		'time-server' => 'option:ntp-server',
	);
	while (my($k, $v) = each %dhcp_multi_options) {
		if ($c->exists($k)) {
			$config_out .= "\t\tdhcp-option=tag:$shared_network,$v," . join(',', $c->returnValues($k)) . "\n";
		}
	}
	$config_out .= $static_mappings_out;
	
	my @global_params = $c->returnValues("subnet-parameters");
	if ( @global_params > 0 ) {
		$config_out .=
			"\n\t\t# The following "
		  . scalar @global_params
		  . " lines were added as subnet-parameters in the CLI and \n"
		  . "\t\t# have not been validated\n";
		foreach my $line (@global_params) {
			my $decoded_line = replace_quot($line);
			$config_out .= "\t\t#$decoded_line\n";
			my $tmp = parse_custom_options($decoded_line, $shared_network);
			if ($tmp) {
				$config_out .= "\t\t$tmp";
			}
			
		}
		$config_out .= "\n";
	}
	$config_out .= "\t#end of subnet $subnet";
}

sub raise_error {
	my $msg = shift;
	my $exit = shift;
	print STDERR $msg . "\n";
	if ($exit) {
		exit(1);
	}
}

sub replace_quot {
    my $line = shift;
    my $count = $line =~ s/\&quot;/\"/g;

    if ( $count != '' and $count % 2 ) {
        raise_error("Error: unbalanced quotes [$line]", 1);
    }
    return $line;
}

sub handle_excludes {
	my ($starts_ref, $statics_ref) = @_;
	my @static_ips = @$statics_ref;
	my @starts = @$starts_ref;
	my @excludes = sort { (new NetAddr::IP($a . "/0")) cmp (new NetAddr::IP($b . "/0")) } ($c->returnValues('exclude'));
	my @stops = ();
	@starts = sort { (new NetAddr::IP($a . "/0")) cmp (new NetAddr::IP($b . "/0")) } @starts;
	my %static_ips_hash = map { $_ => 1 } @static_ips;
	@excludes = grep { !exists($static_ips_hash{$_}) } @excludes; #dnsmasq never dishes out IPs from a range which are used in a static reservation, hence we can ignore those excludes
	
	foreach my $start (@starts) {
		my $stop = $c->returnValue("start $start stop");
		if ($stop eq '') {
			raise_error("Stop DHCP lease IP not defined for Start DHCP lease IP '$start'", 1);
		}
		push(@stops, $stop);
	}
	
	#validate ranges and overlaps
	my @ranges = ();
	my $k = 0;
	for (my $i = 0; $i < @starts; $i++) {
		my $start = new NetAddr::IP($starts[$i] . "/0");
		my $stop = new NetAddr::IP($stops[$i] . "/0");
		if ($stop < $start) {
			raise_error("Range $starts[$i] - $stops[$i] has stop before start", 1);
		}
		if ($i + 1 < @starts) {
			my $j = $i + 1;
			my $test = new NetAddr::IP($starts[$j] . "/0");
			if ($test <= $stop) {
				raise_error("Ranges $starts[$i] - $stops[$i] and $starts[$j] - $stops[$j] overlap", 1);
			}
		}
		#make ranges with excludes
		my $add_range = 1;
		while ($k < @excludes) {
			my $exclude = new NetAddr::IP($excludes[$k] . "/0");
			if ($start == $stop && $start == $exclude) {
				$add_range = 0;
				last;
			}
			elsif ($exclude > $stop) {
				last;
			}
			elsif ($exclude == $start) {
				$start = $start + 1;
				$k++;
			}
			elsif ($exclude == $stop) {
				$k++;
				$stop = $stop - 1;
				last;
			}
			elsif ($start < $exclude && $stop > $exclude) {
				my %range = ();
				$range{start} = $start->addr();
				$range{stop} = ($exclude - 1)->addr();
				push (@ranges, \%range);
				$start = $exclude + 1;
				$k++;
			}
			else {
				#exclude is < $start, so we don't care
				$k++;
			}
		}
		if ($add_range) {
			my %range = ();
			$range{start} = $start->addr();
			$range{stop} = $stop->addr();
			push(@ranges, \%range);
		}
	}
	return @ranges;
}

sub get_interfaces {
	my @intfs;
	my $res = `ls -1 /sys/class/net`;
	my @tmp = split("\n", $res);
	foreach (@tmp) {
		if (!($_ =~ /^\./) && $_ ne "lo" && !($_ =~ /^ifb_/) && $_ ne "bonding_masters") {
			my $tmpintf = $_;
			my @ips = get_ip_for_interface($tmpintf);
			foreach my $ip (@ips) {
				my %intf = ();
				$intf{intf} = $tmpintf;
				$intf{ip} = new NetAddr::IP($ip);
				push(@intfs, \%intf);
			}
		}
	}
	return @intfs;
}

sub get_ip_for_interface {
	my @res;
	my $intf = shift;
	my $tmp = `ip addr show dev $intf | grep 'inet ' | awk '{print \$2;}'`;
	$tmp =~ s/^\s+|\s+$//g;
	my @ips = split("\n", $tmp);
	foreach my $ip (@ips) {
		if ($ip ne "") {
			push(@res, $ip);
		}
	}
	return @ips;
}

sub parse_custom_option_code {
	my $str = shift;
	#option voip-tftp-server code 150 = ip-address;"
	if ($str =~ /^\s*option\s+([^\s]+)\s+code\s+(\d+)\s*=\s*ip-address\s*;\s*$/) {
		$custom_options{$1} = $2;
	}
}

sub parse_custom_options {
	my $str = shift;
	my $tag = shift;
	#option voip-tftp-server 192.168.1.50;
	if ($str =~ /^\s*option\s+([^\s]+)\s+(\d+\.\d+\.\d+\.\d+)\s*;\s*$/) {
		if (exists($custom_options{$1})) {
			return "dhcp-option=tag:$tag," . $custom_options{$1} . ",$2\n";
		}
	}
	return "";
}