# Copyright 2018 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OMG.Watcher.Challenger.CoreTest do
  use ExUnitFixtures
  use ExUnit.Case, async: true

  alias OMG.API.State.Transaction
  alias OMG.API.Utxo
  alias OMG.Watcher.Challenger.Challenge
  alias OMG.Watcher.Challenger.Core
  alias OMG.Watcher.DB.TransactionDB
  alias OMG.Watcher.DB.TxOutputDB

  require Utxo

  deffixture transactions do
    [
      create_transaction(0, 5, 0),
      create_transaction(1, 0, 2),
      create_transaction(2, 1, 3)
    ]
  end

  defp create_transaction(txindex, amount1, amount2) do
    signed = %Transaction.Signed{
      raw_tx: %Transaction{
        blknum1: 1,
        txindex1: 0,
        oindex1: 0,
        blknum2: 1,
        txindex2: 0,
        oindex2: 1,
        cur12: <<0::160>>,
        newowner1: <<1::160>>,
        amount1: amount1,
        newowner2: <<0::160>>,
        amount2: amount2
      },
      sig1: <<0::520>>,
      sig2: <<0::520>>
    }

    txhash = Transaction.Signed.signed_hash(signed)

    %TransactionDB{
      blknum: 2,
      txindex: txindex,
      txhash: txhash,
      inputs: [
        %TxOutputDB{creating_tx_oindex: 0, spending_tx_oindex: 0}
      ],
      outputs: [
        %TxOutputDB{creating_tx_oindex: 0, amount: amount1},
        %TxOutputDB{creating_tx_oindex: 1, amount: amount2}
      ],
      txbytes: Transaction.Signed.encode(signed)
    }
  end

  @tag fixtures: [:transactions]
  test "creates a challenge for an exit; provides utxo position of non-zero amount", %{transactions: transactions} do
    challenging_tx = transactions |> Enum.at(0)
    expected_cutxopos = Utxo.position(2, 0, 0) |> Utxo.Position.encode()
    assert %Challenge{cutxopos: ^expected_cutxopos, eutxoindex: 0} = Core.create_challenge(challenging_tx, transactions)

    challenging_tx = transactions |> Enum.at(1)
    expected_cutxopos = Utxo.position(2, 1, 1) |> Utxo.Position.encode()
    assert %Challenge{cutxopos: ^expected_cutxopos, eutxoindex: 0} = Core.create_challenge(challenging_tx, transactions)

    challenging_tx = transactions |> Enum.at(2)
    expected_cutxopos = Utxo.position(2, 2, 0) |> Utxo.Position.encode()
    assert %Challenge{cutxopos: ^expected_cutxopos, eutxoindex: 0} = Core.create_challenge(challenging_tx, transactions)
  end
end
