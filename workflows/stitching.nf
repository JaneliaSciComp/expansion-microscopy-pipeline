include {
    spark_cluster;
    run_spark_app_on_existing_cluster as run_parse_tiles;
    run_spark_app_on_existing_cluster as run_tiff2n5;
    run_spark_app_on_existing_cluster as run_flatfield_correction;
    run_spark_app_on_existing_cluster as run_stitching;
    run_spark_app_on_existing_cluster as run_fuse;
    run_spark_app_on_existing_cluster as run_export;
} from '../external-modules/spark/lib/workflows'

include {
    terminate_spark as terminate_pre_stitching;
    terminate_spark as terminate_stitching;
} from '../external-modules/spark/lib/processes'

include {
    entries_inputs_args
} from './stitching_utils'

include {
    index_channel;
} from '../utils/utils'

workflow prepare_tiles_for_stitching {
    take:
    stitching_app
    dataset
    stitching_dir
    channels
    resolution
    axis_mapping
    block_size
    spark_conf
    spark_work_dir
    spark_workers
    spark_worker_cores
    spark_gbmem_per_core
    spark_driver_cores
    spark_driver_memory
    spark_driver_stack
    spark_driver_logconfig

    main:
    def spark_driver_deploy = ''
    def terminate_app_name = 'terminate-pre-stitching'

    // index inputs so that I can pair dataset name with the corresponding spark URI and/or spark working dir
    def indexed_dataset = index_channel(dataset)
    def indexed_stitching_dir = index_channel(stitching_dir)
    def indexed_spark_work_dir = index_channel(spark_work_dir)

    // start a spark cluster
    def spark_cluster_res = spark_cluster(
        spark_conf,
        spark_work_dir,
        spark_workers,
        spark_worker_cores,
        spark_worker_cores * spark_gbmem_per_core,
        terminate_app_name
    ) // [ spark_uri, spark_work_dir ]
    // print spark cluster result
    spark_cluster_res.subscribe {  log.debug "Spark cluster result: $it"  }

    def indexed_spark_uri = spark_cluster_res
        .join(indexed_spark_work_dir, by:1)
        .map {
            def indexed_uri = [ it[2], it[1] ]
            log.debug "Create indexed spark URI from $it -> ${indexed_uri}"
            return indexed_uri
        }

    // create a channel of tuples:  [index, spark_uri, dataset, stitching_dir, spark_work_dir]
    def indexed_data = indexed_spark_work_dir \
        | join(indexed_spark_uri)
        | join(indexed_stitching_dir)
        | join(indexed_dataset) // [ idx, work_dir, uri, stitching_dir, dataset ]

    // prepare parse tiles
    def parse_tiles_args = prepare_app_args(
        "parseTiles",
        "org.janelia.stitching.ParseTilesImageList",
        indexed_data,
        indexed_spark_work_dir, //  here I only want a tuple that has the working dir as the 2nd element
        { dataset_name, dataset_stitching_dir ->
            def args_list = []
            args_list << "-i ${dataset_stitching_dir}/ImageList_images.csv"
            if (resolution) {
                args_list << "-r '${resolution}'"
            }
            if (axis_mapping) {
                args_list << "-a '${axis_mapping}'"
            }
            args_list << "-b ${dataset_stitching_dir}"
            args_list << "--skipMissingTiles"
            args_list.join(' ')
        }
    )
    def parse_res = run_parse_tiles(
        parse_tiles_args.map { it[0] }, // spark uri
        stitching_app,
        parse_tiles_args.map { it[1] }, // main
        parse_tiles_args.map { it[2] }, // args
        parse_tiles_args.map { it[3] }, // log
        terminate_app_name, // terminate name
        spark_conf,
        parse_tiles_args.map { it[4] }, // spark work dir
        spark_workers,
        spark_worker_cores,
        spark_gbmem_per_core,
        spark_driver_cores,
        spark_driver_memory,
        spark_driver_stack,
        spark_driver_logconfig,
        spark_driver_deploy
    )

    // prepare tiff to n5
    def tiff_to_n5_args = prepare_app_args(
        "tiff2n5",
        "org.janelia.stitching.ConvertTIFFTilesToN5Spark",
        indexed_data,
        parse_res,
        { dataset_name, dataset_stitching_dir ->
            def tile_json_inputs = entries_inputs_args(
                dataset_stitching_dir,
                channels,
                '-i',
                '',
                '.json'
            )
            "${tile_json_inputs} --blockSize '${block_size}'"
        }
    )
    def tiff2n5_res = run_tiff2n5(
        tiff_to_n5_args.map { it[0] }, // spark uri
        stitching_app,
        tiff_to_n5_args.map { it[1] }, // main
        tiff_to_n5_args.map { it[2] }, // args
        tiff_to_n5_args.map { it[3] }, // log
        terminate_app_name, // terminate name
        spark_conf,
        tiff_to_n5_args.map { it[4] }, // spark work dir
        spark_workers,
        spark_worker_cores,
        spark_gbmem_per_core,
        spark_driver_cores,
        spark_driver_memory,
        spark_driver_stack,
        spark_driver_logconfig,
        spark_driver_deploy
    )

    // prepare flatfield
    def flatfield_args = prepare_app_args(
        "flatfield",
        "org.janelia.flatfield.FlatfieldCorrection",
        indexed_data,
        tiff2n5_res,
        { dataset_name, dataset_stitching_dir ->
            def n5_json_input = entries_inputs_args(
                dataset_stitching_dir,
                channels,
                '-i',
                '-n5',
                '.json'
            )
            "${n5_json_input} -v 101 --2d --bins 256"
        }
    )
    def flatfield_res = run_flatfield_correction(
        flatfield_args.map { it[0] }, // spark uri
        stitching_app,
        flatfield_args.map { it[1] }, // main
        flatfield_args.map { it[2] }, // args
        flatfield_args.map { it[3] }, // log
        terminate_app_name, // terminate name
        spark_conf,
        flatfield_args.map { it[4] }, // spark work dir
        spark_workers,
        spark_worker_cores,
        spark_gbmem_per_core,
        spark_driver_cores,
        spark_driver_memory,
        spark_driver_stack,
        spark_driver_logconfig,
        spark_driver_deploy
    )

    // terminate stitching cluster
    done = terminate_pre_stitching(
        flatfield_res.map { it[1] },
        terminate_app_name
    )
    | join(indexed_data, by:1) | map { 
        // [ work_dir, <ignored from terminate>,  idx, uri, stitching_dir, dataset]
        log.info "Completed pre stitching for ${it}"
        // dataset_name, stitching_dir
        [ it[5], it[4] ]
    }

    emit:
    done
}

workflow mock_prepare_tiles_for_stitching {
    take:
    stitching_app
    dataset
    stitching_dir
    channels
    resolution
    axis_mapping
    block_size
    spark_conf
    spark_work_dir
    spark_workers
    spark_worker_cores
    spark_gbmem_per_core
    spark_driver_cores
    spark_driver_memory
    spark_driver_stack
    spark_driver_logconfig

    main:
    def spark_driver_deploy = ''
    def terminate_app_name = 'terminate-pre-stitching'

    // index inputs so that I can pair dataset name with the corresponding spark URI and/or spark working dir
    def indexed_dataset = index_channel(dataset)
    def indexed_stitching_dir = index_channel(stitching_dir)

    done = indexed_dataset
        | join(indexed_stitching_dir)
        | map { [it[1], it[2]] }

    emit:
    done
}

workflow stitching {
    take:
    stitching_app
    dataset
    stitching_dir
    channels
    stitching_mode
    stitching_padding
    blur_sigma
    export_level
    spark_conf
    spark_work_dir
    spark_workers
    spark_worker_cores
    spark_gbmem_per_core
    spark_driver_cores
    spark_driver_memory
    spark_driver_stack
    spark_driver_logconfig

    main:
    def spark_driver_deploy = ''
    def terminate_app_name = 'terminate-stitching'

    // index inputs so that I can pair dataset name with the corresponding spark URI and/or spark working dir
    def indexed_dataset = index_channel(dataset)
    def indexed_stitching_dir = index_channel(stitching_dir)
    def indexed_spark_work_dir = index_channel(spark_work_dir)

    // start a spark cluster
    def spark_cluster_res = spark_cluster(
        spark_conf,
        spark_work_dir,
        spark_workers,
        spark_worker_cores,
        spark_worker_cores * spark_gbmem_per_core,
        terminate_app_name
    ) // [ spark_uri, spark_work_dir ]
    // print spark cluster result
    spark_cluster_res.subscribe {  log.debug "Spark cluster result: $it"  }

    def indexed_spark_uri = spark_cluster_res
        .join(indexed_spark_work_dir, by:1)
        .map {
            def indexed_uri = [ it[2], it[1] ]
            log.debug "Create indexed spark URI from $it -> ${indexed_uri}"
            return indexed_uri
        }

    // create a channel of tuples:  [index, spark_uri, dataset, stitching_dir, spark_work_dir]
    def indexed_data = indexed_spark_work_dir \
        | join(indexed_spark_uri)
        | join(indexed_stitching_dir)
        | join(indexed_dataset) // [ idx, work_dir, uri, stitching_dir, dataset ]

    // prepare stitching tiles
    def stitching_args = prepare_app_args(
        "stitch",
        "org.janelia.stitching.StitchingSpark",
        indexed_data,
        indexed_spark_work_dir, //  here I only want a tuple that has the working dir as the 2nd element
        { dataset_name, dataset_stitching_dir ->
            def tile_json_inputs = entries_inputs_args(
                dataset_stitching_dir,
                channels,
                '-i',
                '-decon',
                '.json'
            )
            def args_list = []
            args_list 
                << '--stitch'
                <<  '-r' << '-1'
                << tile_json_inputs
                << '--mode' << "'${stitching_mode}'"
                << '--padding' << "'${stitching_padding}'"
                << '--blurSigma' << "${blur_sigma}"

            args_list.join(' ')
        }
    )
    def stitch_res = run_stitching(
        stitching_args.map { it[0] }, // spark uri
        stitching_app,
        stitching_args.map { it[1] }, // main
        stitching_args.map { it[2] }, // args
        stitching_args.map { it[3] }, // log
        terminate_app_name, // terminate name
        spark_conf,
        stitching_args.map { it[4] }, // spark work dir
        spark_workers,
        spark_worker_cores,
        spark_gbmem_per_core,
        spark_driver_cores,
        spark_driver_memory,
        spark_driver_stack,
        spark_driver_logconfig,
        spark_driver_deploy
    )

    // prepare fuse tiles
    def fuse_args = prepare_app_args(
        "fuse",
        "org.janelia.stitching.StitchingSpark",
        indexed_data,
        stitch_res,
        { dataset_name, dataset_stitching_dir ->
            def tile_json_inputs = entries_inputs_args(
                dataset_stitching_dir,
                channels,
                '-i',
                '-decon-final',
                '.json'
            )
            def args_list = []
            args_list 
                << '--fuse'
                << tile_json_inputs
                << '--blending'

            args_list.join(' ')
        }
    )
    def fuse_res = run_fuse(
        fuse_args.map { it[0] }, // spark uri
        stitching_app,
        fuse_args.map { it[1] }, // main
        fuse_args.map { it[2] }, // args
        fuse_args.map { it[3] }, // log
        terminate_app_name, // terminate name
        spark_conf,
        fuse_args.map { it[4] }, // spark work dir
        spark_workers,
        spark_worker_cores,
        spark_gbmem_per_core,
        spark_driver_cores,
        spark_driver_memory,
        spark_driver_stack,
        spark_driver_logconfig,
        spark_driver_deploy
    )

    // prepare export tiles
    def export_args = prepare_app_args(
        "export",
        "org.janelia.stitching.N5ToSliceTiffSpark",
        indexed_data,
        fuse_res,
        { dataset_name, dataset_stitching_dir ->
            def args_list = []
            args_list 
                << '-i' << "${dataset_stitching_dir}/export.n5"
                << '--scaleLevel' << "${export_level}"

            args_list.join(' ')
        }
    )
    def export_res = run_export(
        fuse_args.map { it[0] }, // spark uri
        stitching_app,
        fuse_args.map { it[1] }, // main
        fuse_args.map { it[2] }, // args
        fuse_args.map { it[3] }, // log
        terminate_app_name, // terminate name
        spark_conf,
        fuse_args.map { it[4] }, // spark work dir
        spark_workers,
        spark_worker_cores,
        spark_gbmem_per_core,
        spark_driver_cores,
        spark_driver_memory,
        spark_driver_stack,
        spark_driver_logconfig,
        spark_driver_deploy
    )

    // terminate stitching cluster
    done = terminate_stitching(
        export_res.map { it[1] },
        terminate_app_name
    )
    | join(indexed_data, by:1) | map { 
        // [ work_dir, <ignored from terminate>,  idx, uri, stitching_dir, dataset]
        log.info "Completed stitching for ${it}"
        // dataset_name, stitching_dir
        [ it[5], it[4] ]
    }

    emit:
    done

}

def prepare_app_args(app_name,
                     app_main,
                     indexed_data,
                     previous_result_dir,
                     app_args_closure) {
    return indexed_data
    | join(previous_result_dir, by: 1)
    | map {
        // [ work_dir, idx, uri, stitching_dir, dataset, <ignored elem from prev res> ]
        log.debug "Create ${app_name} inputs from ${it}"
        def idx = it[1]
        def spark_work_dir = it[0] // spark work dir is the key
        def dataset = it[4]
        def spark_uri = it[2]
        def stitching_dir = it[3]
        def app_args = app_args_closure.call(dataset, stitching_dir)
        def app_inputs = [
            spark_uri,
            app_main,
            app_args,
            "${app_name}.log",
            spark_work_dir
        ]
        log.debug "${app_name} app input ${idx}: ${app_inputs}"
        return app_inputs
    }
}
