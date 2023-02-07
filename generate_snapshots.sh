#!/bin/bash
set -Eeuo pipefail

setup_vars() {
    # Define bins
    DEFID_BIN=${DEFID_BIN:-"defid"}
    DEFI_CLI_BIN=${DEFI_CLI_BIN:-"defi-cli"}

    # Define files and directories
    DATADIR=${DATADIR:-".defi"}
    DEBUG_FILE="$DATADIR/debug.log"
    GS_BUCKET=gs://team-drop
    GCP_DATADIR_FOLDER=${GCP_DATADIR_FOLDER:-"master-datadir-tmp"}
    DATADIR_FOLDER=$GS_BUCKET/$GCP_DATADIR_FOLDER
    GREP=${GREP:-"grep"}

    # Define commands
    DEFID_CMD="$DEFID_BIN -datadir=$DATADIR -daemon -debug=accountchange -spv=1"

    if [[ $WITH_CHECKPOINTS == "1" ]]; then
        CHECKPOINTS_FILE=${CHECKPOINTS_FILE:-"checkpoints.txt"}
        DEFID_CMD+= " -checkpoints-file=$CHECKPOINTS_FILE"
    fi

    if [[ $PRUNE == "1" ]]; then
        PRUNE_SIZE=${PRUNE_SIZE:-550}
        DEFID_CMD+= " -prune=$PRUNE_SIZE"
    fi

    DEFI_CLI_CMD="$DEFI_CLI_BIN -datadir=$DATADIR"

    # Define start block and block range
    BLOCK_RANGE=${BLOCK_RANGE:-50000}
    START_BLOCK=${START_BLOCK:-0}
    TARGET_BLOCK=$(($START_BLOCK + $BLOCK_RANGE))

    echo "Starting from START_BLOCK : $START_BLOCK to TARGET_BLOCK : $TARGET_BLOCK with BLOCK_RANGE: $BLOCK_RANGE"

    ATTEMPTS=0
    MAX_ATTEMPTS=3
    MAX_NODE_RESTARTS=5
    NODE_RESTARTS=0
}

start_node () {
    echo "Syncing to block height: $TARGET_BLOCK"
    $DEFID_CMD -interrupt-block=$((TARGET_BLOCK + 1))
    sleep 60
}

create_snapshot () {
    echo "Creating snapshot $TMP_DATADIR"
    # Using different port and rpc_port lest it conflicts with main defid process
    PORT=99$(printf "%02d\n" $I)
    RPC_PORT=89$(printf "%02d\n" $I)

    TARBALL=datadir-$TARGET_BLOCK.tar.gz

    # Restarts defid on another port with -connect=0 to reconsider block invalidated by interrupt-block flag
    $DEFID_BIN -daemon -datadir=$TMPDIR -connect=0 -rpcport=$RPC_PORT -port=$PORT
    sleep 60
    BEST_BLOCK_HASH=$($DEFI_CLI_BIN -datadir=$TMPDIR -rpcport=$RPC_PORT getbestblockhash)
    echo "Reconsidering block : $BEST_BLOCK_HASH"
    $DEFI_CLI_BIN -datadir=$TMPDIR -rpcport=$RPC_PORT reconsiderblock $BEST_BLOCK_HASH
    $DEFI_CLI_BIN -datadir=$TMPDIR -rpcport=$RPC_PORT stop
    sleep 60

    rm $TMPDIR/*
    rm -rf $TMPDIR/wallets
    cd $TMPDIR && tar -czvf ../$TARBALL $(ls) && cd ..
    rm -rf $TMPDIR

    # upload snapshot to GCP
    gsutil cp $TARBALL $DATADIR_FOLDER/$TARBALL
    rm $TARBALL

    I=$(($I + 1))
}

reconsider_latest_block () {
    $DEFI_CLI_CMD reconsiderblock $($DEFI_CLI_CMD getbestblockhash)
    $DEFI_CLI_CMD clearbanned
}

main() {
    setup_vars
    start_node
    I=0

    while true; do
        TMP_BLOCK=${CURRENT_BLOCK:-0}
        CURRENT_BLOCK=$($DEFI_CLI_CMD getblockcount || echo $CURRENT_BLOCK)
        TIP_HEIGHT=$($DEFI_CLI_CMD getblockchaininfo | grep headers | awk '{print $2}' | sed 's/.$//')

        echo "CURRENT_BLOCK : $CURRENT_BLOCK"
        echo "TIP_HEIGHT : $TIP_HEIGHT"

        if [ "$CURRENT_BLOCK" -eq "$TMP_BLOCK" ] && [ "$CURRENT_BLOCK" -ne "$TIP_HEIGHT" ]; then
            ATTEMPTS=$((ATTEMPTS + 1))
        else
            ATTEMPTS=0
        fi

        if [ "$ATTEMPTS" -gt "$MAX_ATTEMPTS" ]; then
            if [ "$NODE_RESTARTS" -lt "$MAX_NODE_RESTARTS" ]; then
                echo "Node Stuck After $ATTEMPTS attempts, restarting node"
                $DEFI_CLI_CMD stop
                sleep 60
                start_node
                NODE_RESTARTS=$((NODE_RESTARTS + 1))
                ATTEMPTS=0
            else
                echo "exiting after $MAX_NODE_RESTARTS restarts"
                echo "stopping node..."
                $DEFI_CLI_CMD stop
                exit 1
            fi
        fi

        if [ $CURRENT_BLOCK -eq $TARGET_BLOCK ]; then
            echo "AT TARGET_BLOCK : $TARGET_BLOCK"

            $DEFI_CLI_CMD stop
            sleep 60

            # Remove all files that should not be added to snapshot
            rm .defi/*
            rm -rf .defi/wallets

            # Create backup before generating snapshot
            TMPDIR="tmpdir-$TARGET_BLOCK"
            cp -r .defi $TMPDIR

            create_snapshot &

            # Restart node and set interrupt to next block range
            TARGET_BLOCK=$(($TARGET_BLOCK + $BLOCK_RANGE))
            $DEFID_CMD -interrupt-block=$(($TARGET_BLOCK + 1))
            sleep 60
            reconsider_latest_block
        else
            sleep 60
        fi
    done
}

main "$@"
