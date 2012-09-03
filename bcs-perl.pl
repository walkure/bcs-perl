#!/usr/bin/env perl

# BonCasServer(perl version) by walkure at 3pf.jp
# 02 Dec 2009 first release.
# 03 Dec 2009 re-open card when card is re-entered , show B-CAS style card uID

use strict;
use warnings;

use bigint;

use Chipcard::PCSC;
use Chipcard::PCSC::Card;
use IO::Socket;
use IO::Select;

##################
#configure section

#selected SC reader
#my $selected_reader = 'SCM SCR 3310 NTTCom 00 00';
my $selected_reader = 'SCM SCR 3310 NTTCom [Vendor Interface] (21120651345180) 00 00';
#listen port
my $listen_port     = 6900;
#bind address
my $bind_addr       = '0.0.0.0';

#############
#code section

#create reader object
my $context = new Chipcard::PCSC();
die "Can't create the PCSC object: $Chipcard::PCSC::errno\n" unless defined $context;

#show reader list
if(@ARGV && $ARGV[0] eq 'list'){
	my @readers = $context->ListReaders();
	die "Can't get reader list: $Chipcard::PCSC::errno\n" unless defined $readers[0];
	
	print ">>List of PC/SC card reader\n";
	foreach(@readers){
		print "$_\n";
	}
	print ">>EOL\n";
	exit;
}

#open card
my $card = initCard($context);
exit unless defined $card;

#create server socket
my $serv_sock = new IO::Socket::INET(
	Listen    => SOMAXCONN ,
	LocalAddr => $bind_addr ,
	LocalPort => $listen_port ,
	Proto     => 'tcp' ,
	Reuse     => 1
);
die "IO::Socket : $!" unless $serv_sock;

#using select
my $sel = IO::Select->new;
$sel->add($serv_sock);

#accept connection
print ">>Begin Listening($bind_addr:$listen_port).....\n";
my %hosts;

while(1){

	#Timeout undefined(infinite)
	my ($active_socks) = IO::Select->select($sel,undef,undef,undef);
	
	#check if card is ejected
	if(defined $card){
		my $stat =  $card->Status();
		$card = initCard($context) unless defined $stat;
	}else{
		$card = initCard($context,1);
	}
	
	next unless defined $card;
	
	foreach my $sock (@{$active_socks}){
		if ( $sock == $serv_sock ){
			my $new_sock = $serv_sock->accept;
			$hosts{$new_sock} = $new_sock->peerhost().':'.$new_sock->peerport();
			print ">>Connected from $hosts{$new_sock}\n";
			$sel->add($new_sock);
		} else {
			my ($len,$req);
			
			#Data format : length data1 data2 data3 ... datan
			$sock->recv($len,1,MSG_WAITALL);
			$len = unpack('C',$len);
			if($len){
				$sock->recv($req,$len,MSG_WAITALL);
				
				my @req_array = unpack('C*',$req);
				my $res_array = $card->Transmit(\@req_array);
				
				die "Chipcard::PCSC::Card::Transmit returned error:$Chipcard::PCSC::errno\n" unless defined $res_array;
				
				my $res_len = scalar @$res_array;
				
				unshift(@$res_array,$res_len);
				my $res = pack('C*',@$res_array);
				$sock->send($res,$res_len+1);
				
				$sock->flush();
			} else {
			
				$sel->remove($sock);
				print ">>Disconnected from $hosts{$sock}\n";
				delete $hosts{$sock};
				$sock->close();
			}
		}
	}
}

exit;

sub initCard
{
	my ($context,$hide_nocarderr) = @_;
	
	my $card = new Chipcard::PCSC::Card (
		$context,
		$selected_reader,
		$Chipcard::PCSC::SCARD_SHARE_SHARED,
		$Chipcard::PCSC::SCARD_PROTOCOL_T1
	);

	unless(defined $card){
		print"Cannot open PCSC card:$Chipcard::PCSC::errno\n" unless defined $hide_nocarderr;
		return undef;
	}

	#check card ATR
	my ($reader_name, $reader_state, $protocol, $atr) =  $card->Status();
	my @bcas_atr = (0x3b,0xf0,0x12,0x00,0xff,0x91,0x81,0xb1,0x7c,0x45,0x1f,0x03,0x99);
	foreach(0 .. scalar @$atr - 1){
		if($atr->[$_] != $bcas_atr[$_]){
			print "Unknown ATR found... maybe target card isn't B-CAS CARD\nCard's ATR:";
			foreach(@$atr){
				printf '%02X ',$_;
			}
			print "\n B-CAS ATR:";
			foreach(@bcas_atr){
				printf '%02X ',$_;
			}
			print "\n";
			return undef;
		}
	}

	#show cards status
	print ">>Reader:$reader_name\n";
	print '>>Card Status:';
	print '[Unknown State]'		if($reader_state & $Chipcard::PCSC::SCARD_UNKNOWN);
	print '[Card Absent]'		if($reader_state & $Chipcard::PCSC::SCARD_ABSENT);
	print '[Card Present]'		if($reader_state & $Chipcard::PCSC::SCARD_PRESENT);
	print '[Not Powered]'		if($reader_state & $Chipcard::PCSC::SCARD_SWALLOWED);
	print '[Powered]'			if($reader_state & $Chipcard::PCSC::SCARD_POWERED);
	print '[Ready for PTS]'		if($reader_state & $Chipcard::PCSC::SCARD_NEGOTIABLE);
	print '[PTS has been set]'	if($reader_state & $Chipcard::PCSC::SCARD_SPECIFIC);
	print "\n";
	
	#init card
	my @init_cmd = (0x90, 0x30, 0x00, 0x00, 0x00);
	my $init_res_array = $card->Transmit(\@init_cmd);

	unless(defined $init_res_array){
		print "Cannot initalize B-CAS card:$Chipcard::PCSC::errno\n";
		return undef;
	}
	
	if(scalar @$init_res_array < 57){
		print 'Initialize Error! response size['.scalar @$init_res_array."] is smaller than 57 !\n";
		return undef;
	}
	
	my @info_cmd = (0x90, 0x32, 0x00, 0x00, 0x00);
	my $info_res_array = $card->Transmit(\@info_cmd);

	unless(defined $info_res_array){
		print "Cannot get info B-CAS card:$Chipcard::PCSC::errno\n";
		return undef;
	}
	
	if(scalar @$info_res_array < 17){
		print 'infoResponse Error! response size['.scalar @$info_res_array."] is smaller than 17 !\n";
		return undef;
	}
	
	printf ">>Card Ver:%d\n",$info_res_array->[8];
	printf ">>Card Manufacture ID:%c\n",$info_res_array->[7];
	
	my @uid = formatCardId(
		$info_res_array->[15] << 8 | $info_res_array->[16] ,
		$init_res_array->[8],
		$init_res_array->[9],
		$init_res_array->[10],
		$init_res_array->[11],
		$init_res_array->[12],
		$init_res_array->[13],
	);
	
	print ">>Card ID: $uid[0] $uid[1] $uid[2] $uid[3] $uid[4]\n";
	
	$card;
}

sub formatCardId
{
	my ($check,@uid) = @_;
	
	#requires 'use bigint;'
	my $id = sprintf('0x%02x%02x%02x%02x%02x%02x',
		$uid[0],$uid[1],$uid[2],$uid[3],$uid[4],$uid[5],
	);
	
	$id *= 100000;
	$id += $check;
	
	(
		sprintf('%d%03d',$uid[0] >> 5,($id / (10000 * 10000 * 10000 * 10000)) % 10000),
		sprintf('%04d',($id / (10000 * 10000 * 10000)) % 10000),
		sprintf('%04d',($id / (10000 * 10000)) % 10000),
		sprintf('%04d',($id / 10000) % 10000),
		sprintf('%04d',$id % 10000),
	);
}

