  ($amap | INDEX(.address)) as $M
  | ($utxos[0]) as $U
  | def mkutxo($M):
      . as $u
      | ($M[$u.address].base16) as $b
      | ($b[0:2]) as $h
      | {
          txHash: ($u.tx_hash // $txid),
          index: $u.output_index,
          paymentKind: (if ($h=="71" or $h=="11" or $h=="31" or $h=="21") then "script" else "key" end),
          paymentHash: $b[2:58],
          stakeKind: (if ($h=="01" or $h=="11") then "key" elif ($h=="21" or $h=="31") then "script" else null end),
          stakeHash: (if ($b|length) > 58 then $b[58:114] else null end),
          lovelace: ([$u.amount[]|select(.unit=="lovelace")|.quantity][0]|tonumber),
          assets: [ $u.amount[] | select(.unit!="lovelace") | [ .unit[0:56], .unit[56:], (.quantity|tonumber) ] ],
          datumHex: $u.inline_datum,
          refScriptHash: $u.reference_script_hash
        };
  {
    validFrom: $validFrom, validTo: $validTo, fee: $fee,
    poolLocation: 0, agentLocation: 2, requestLocations: [[1,0]],
    inputs: ([ $U.inputs[] | select(.reference!=true and .collateral!=true) ]
            | sort_by(.tx_hash, .output_index) | map(mkutxo($M))),
    refInputs: ([ $U.inputs[] | select(.reference==true) ] | sort_by(.tx_hash, .output_index) | map(mkutxo($M))),
    outputs: ([ $U.outputs[] | . + {tx_hash:$txid} ] | map(mkutxo($M)))
  }
