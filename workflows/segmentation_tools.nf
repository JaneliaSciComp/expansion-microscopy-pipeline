
include {
    unet_classifier;
    segmentation_postprocessing;
} from '../processes/synapse_detection'

include {
    merge_2_channels;
    merge_3_channels;
    merge_4_channels;
    duplicate_h5_volume;
} from '../processes/utils'

// Call the UNet classifier if the model is defined or simply return the input if no model
workflow classify_regions_in_volume {
    take:
    input_image // input image filename
    volume // image volume as a map [width: <val>, height: <val>, depth: <val>]
    model // classifier's model
    output_image // output image filename

    main:
    def classifier_data = merge_3_channels(input_image, volume, model)
    | join(duplicate_h5_volume(input_image, volume, output_image), by: 0)
    // [ input, volume, model, output]

    def unet_inputs = classifier_data
    | filter { it[2] } // filter based on the model
    | flatMap {
        def img_fn = it[0] // image file name
        def img_vol = it[1] // image volume
        def classifier = it[2] // classifier's model
        def out_img_fn = it[3] // output image file name
        partition_volume(img_fn, img_vol, params.volume_partition_size, [classifier, out_img_fn])
    } // [ img_file, img_subvol, model, out_img_file ]

    def unet_classifier_results = unet_classifier(
        unet_inputs.map { it[0] }, // input image
        unet_inputs.map { it[2] }, // model
        unet_inputs.map { it[1] }, // subvolume
        unet_inputs.map { it[3] } // output image
    )
    | groupTuple(by: [0,1])
    | map {
        [ it[0], it[1] ] // [ input_img, output_img ]
    }
    | join(classifier_data, by:0)
    | map {
        // [ input_image, output_image, volume, model, output_image]
        [ it[0], it[2], it[1] ] 
    } // [ input_image_file, image_volume, output_image_file ]

    def non_classified_results = classifier_data
    | filter { !it[2] }
    | map {
        def img_fn = it[0] // image file name
        def img_vol = it[1] // image volume
        [ img_fn, img_vol, img_fn ]
    }

    emit:
    done = unet_classifier_results | mix(non_classified_results)
}

// connect and select regions from input image that are above a threshold
// if a mask is defined only select the regions that match the mask
workflow connect_regions_in_volume {
    take:
    input_image_filename
    image_volume
    mask_filename
    mask_volume
    output_image_filename

    main:
    def mask_data = merge_4_channels(input_image_filename, mask_filename, image_volume, mask_volume)
    | map {
        def mask_fn = it[1]
        def m_vol = mask_fn ? it[3] : it[2]
        it[0..2] + m_vol
    }
    | join(duplicate_h5_volume(input_image_filename, image_volume, output_image_filename), by: 0)
    // [ input_img, mask, image_volume, mask_volume, output_img]

    def postprocessing_inputs = mask_data
    | flatMap {
        def img_fn = it[0]
        def img_vol = it[2]
        def mask_fn = it[1]
        def mask_vol = it[3]
        def out_img_fn = it[4]
        partition_volume(mask_fn, mask_vol, params.volume_partition_size, [img_fn, img_vol, out_img_fn])
    } // [ mask_file, subvol, in_img_file, img_vol, out_img_file]

    def postprocessing_results = segmentation_postprocessing(
        postprocessing_inputs.map { it[2] }, // input image file,
        postprocessing_inputs.map { it[0] }, // mask file
        postprocessing_inputs.map { it[1] }, // subvol
        params.synapse_mask_threshold,
        params.synapse_mask_percentage,
        postprocessing_inputs.map { it[4] } // output image file
    )
    | groupTuple(by: [0..2])
    | map {
        // drop subvolume
        it[0..2] // [ input_image_file, mask_file, output_image_file ]
    }
    | join(mask_data, by:[0,1])
    | map {
        // [ input_image, mask, output_image, image_vol, mask_vol, output_image ]
        [ it[0], it[3], it[1], it[4], it[2] ]
    } // [ input_image, image_volume, mask_image, mask_volume, output_image ]

    emit:
    done = postprocessing_results
}

workflow classify_and_connect_regions {
    take:
    input_image_filename
    image_volume
    model_filename
    mask_filename
    mask_volume
    classifier_output_filename
    post_classifier_output_filename

    main:
    def classifier_results = classify_regions_in_volume(
        input_image_filename,
        image_volume,
        model_filename,
        classifier_output_filename
    ) // [ input_image, input_image_vol, classifier_output ]

    def mask_data = merge_4_channels(
        input_image_filename,
        mask_filename,
        mask_volume,
        post_classifier_output_filename
    )

    def post_classifier_inputs = classifier_results
    | join(mask_data, by:0)
    // [ input_image, input_image_vol, classifier_output, mask, mask_vol, post_classifier_output ]

    def post_classifier_results = connect_regions_in_volume(
        post_classifier_inputs.map { it[2] }, // classifier_output
        post_classifier_inputs.map { it[1] }, // image vol
        post_classifier_inputs.map { it[3] }, // mask
        post_classifier_inputs.map { it[4] }, // mask_vol
        post_classifier_inputs.map { it[5] } // post_classifier_output
    ) // [ classifier_output, image_vol, mask, mask_vol, post_classifier_output ]
    | map {
        def classifier_output = it[0]
        def image_vol = it[1]
        def mask = it[2]
        def mask_vol = it[3]
        def post_classifier_output = it[4]
        [
            post_classifier_output, classifier_output, mask, image_vol, mask_vol
        ]
    } // [ post_classifier_output, classifier_output, mask, image_vol, mask_vol ]

    done = merge_2_channels(
        post_classifier_output_filename,
        input_image_filename
    ) // [ post_classifier_output, input_image ]
    | join(post_classifier_results, by:0)
    | map {
        // [ post_classifier_output, input_image, classifier_output, mask, image_vol, mask_vol ]
        def input_image = it[1]
        def classifier_output = it[2]
        def post_classifier_output = it[0]
        def mask = it[3]
        def image_vol = it[4]
        def mask_vol = it[5]
        [
            input_image, image_vol, mask, mask_vol, classifier_output, post_classifier_output
        ]
    }

    emit:
    done
}

def partition_volume(fn, volume, partition_size, additional_fields) {
    def width = volume.width
    def height = volume.height
    def depth = volume.depth
    def ncols = ((width % partition_size) > 0 ? (width / partition_size + 1) : (width / partition_size)) as int
    def nrows =  ((height % partition_size) > 0 ? (height / partition_size + 1) : (height / partition_size)) as int
    def nslices = ((depth % partition_size) > 0 ? (depth / partition_size + 1) : (depth / partition_size)) as int
    log.info "Partition $fn of size $volume into $ncols x $nrows x $nslices subvolumes"
    [0..ncols-1, 0..nrows-1, 0..nslices-1]
        .combinations()
        .collect {
            def start_col = it[0] * partition_size
            def end_col = start_col + partition_size
            if (end_col > width) {
                end_col = width
            }
            def start_row = it[1] * partition_size
            def end_row = start_row + partition_size
            if (end_row > height) {
                end_row = height
            }
            def start_slice = it[2] * partition_size
            def end_slice = start_slice + partition_size
            if (end_slice > depth) {
                end_slice = depth
            }
            def sub_vol = [
                fn,
                "${start_col},${start_row},${start_slice},${end_col},${end_row},${end_slice}",
            ]
            if (additional_fields) {
                sub_vol + additional_fields
            } else {
                sub_vol
            }
        }
}
