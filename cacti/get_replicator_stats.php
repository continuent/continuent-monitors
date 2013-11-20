<?php

/**
 * Modify these values for your environment
 */
$ssh_user = 'root';
$ssh_options = '-o "ConnectTimeout 20" -o "PreferredAuthentications publickey" -o "IdentitiesOnly yes" -o "StrictHostKeyChecking no"';
$cache_dir = '/tmp';
$tungsten_home = '/opt/continuent/tungsten';

/**
 * Parse the command line options to pull the hostname
 */
$trepctl_service = "";
for ( $i = 1; $i < count($_SERVER["argv"]); $i++ ) {
  $key = $_SERVER["argv"][$i];
  if (strpos($key, "--") === 0 && array_key_exists($i+1, $_SERVER["argv"])) {
    $value = $_SERVER["argv"][$i+1];
    $i++;
  } else {
    $value = null;
  }
  switch ($key) {
    case '--hostname':
      $ssh_hostname = $value;
      break;
    case '--service':
      $trepctl_service = $value;
      break;
  }
}

/**
 * The hostname is required in order to run
 */
if ($ssh_hostname === null) {
  fprintf(STDERR, "Unable to process because --hostname is not specified\n");
  exit(1);
}

if ($cache_dir !== null) {
  $cache_filename = $cache_dir . DIRECTORY_SEPARATOR . 'cache_cacti_tungsten_' . str_replace(array(":", "/"), array("", "_"), $ssh_hostname) . '_' . $trepctl_service;

  /**
   * See if the cache file is available, recent and not empty
   */
  if (filesize($cache_filename) > 0 && (filectime($cache_filename) + 30 > time())) {
    echo file_get_contents($cache_filename);
    exit(0);
  }
} else {
  $cache_filename = null;
}

/**
 * Pull the replicator status and parse out the tracking values
 */
if ($trepctl_service != "") {
  $trepctl_service_option = "-service $trepctl_service";
} else {
  $trepctl_service_option = "";
}
$command = "$tungsten_home/tungsten-replicator/bin/trepctl $trepctl_service_option status | tr -d \" \"";
$replicator_status = `ssh $ssh_user@$ssh_hostname $ssh_options $command`;

$results = array();
$online = 0;
$offline = 0;
$error = 0;
$other = 0;
foreach (explode("\n", $replicator_status) as $line) {
  $p = strpos($line, ":");
  $key = substr($line, 0, $p);
  $value = substr($line, $p+1);
  
  switch ($key) {
    case 'uptimeSeconds':
      $results[] = "up:$value";
      break;
    case 'timeInStateSeconds':
      $results[] = "tis:$value";
      break;
    case 'appliedLastSeqno':
      $results[] = "seq:$value";
      break;
    case 'appliedLatency':
      $results[] = "lat:$value";
      break;
    case 'state':
      switch ($value) {
        case 'ONLINE':
          $online++;
          break;
        case 'OFFLINE:NORMAL':
          $offline++;
          break;
        case 'OFFLINE:ERROR':
        case 'SUSPECT':
          $error++;
          break;
        default:
          $other++;
          break;
      }
      break;
  }
}

$results[] = "on:$online";
$results[] = "off:$offline";
$resutls[] = "err:$error";
$results[] = "oth:$other";

$result_string = implode(" ", $results);

/**
 * Write out the cache file
 */
if ($cache_filename !== null) {
  $fp = fopen($cache_filename, "a+");
  ftruncate($fp, 0);
  fprintf($fp, $result_string);
  fclose($fp);
}

echo $result_string;