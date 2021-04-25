#!/usr/bin/env python

import argparse
import gc
import time
import numpy as np
from tensorflow.keras.models import load_model
from tensorflow.keras import backend as K
from n5_utils import read_n5_block, write_n5_block

def masked_binary_crossentropy(y_true, y_pred):
    mask = K.cast(K.not_equal(y_true,2), K.floatx())
    score = K.mean(K.binary_crossentropy(y_pred*mask, y_true*mask), axis=-1)
    return score


def masked_accuracy(y_true, y_pred):
    mask = K.cast(K.not_equal(y_true,2), K.floatx())
    score = K.mean(K.equal(y_true*mask, K.round(y_pred*mask)), axis=-1)
    return score


def masked_error_pos(y_true, y_pred):
    mask = K.cast(K.equal(y_true,1), K.floatx())
    error = (1-y_pred) * mask
    score = K.sum(error) / K.maximum(K.sum(mask),1)
    return score


def masked_error_neg(y_true, y_pred):
    mask = K.cast(K.equal(y_true,0), K.floatx())
    error = y_pred * mask
    score = K.sum(error) / K.maximum(K.sum(mask),1)
    return score


def apply_unet(img, model_path, input_sz=(64,64,64), step=(24,24,24), mask=None):
    '''
    Test 3D U-Net on an image data
    args:
    img: image data for testing
    input_sz: U-net input size
    step: number of voxels to move the sliding window in x-,y-,z- direction
    mask: (optional) a mask applied to the img
    '''
    
    print("Doing prediction using 3D U-Net...", flush=True)
    if mask is not None:
        assert mask.shape == img.shape, \
            "Mask and image shapes do not match!"

    unet_model = load_model(model_path, custom_objects={'masked_binary_crossentropy':masked_binary_crossentropy, \
        'masked_accuracy':masked_accuracy, 'masked_error_pos':masked_error_pos, 'masked_error_neg':masked_error_neg})

    img = img.astype('float64', casting='safe')
    
    img = (img - img.mean()) / img.std()

    print("Running U-Net...", flush=True)

    # expand the image to deal with edge issue
    gap = (int((input_sz[0]-step[0])/2), int((input_sz[1]-step[1])/2), int((input_sz[2]-step[2])/2))
    new_img = np.zeros((img.shape[0]+gap[0]+input_sz[0], img.shape[1]+gap[1]+input_sz[1], img.shape[2]+gap[2]+input_sz[2]), dtype=img.dtype)
    new_img[gap[0]:new_img.shape[0]-input_sz[0], gap[1]:new_img.shape[1]-input_sz[1], gap[2]:new_img.shape[2]-input_sz[2]] = img
    img = new_img
    del new_img
    predict_img = np.zeros(img.shape, dtype=img.dtype)

    for row in range(0, img.shape[0]-input_sz[0], step[0]):
        for col in range(0, img.shape[1]-input_sz[1], step[1]):
            for vol in range(0, img.shape[2]-input_sz[2], step[2]):
                patch_img = np.zeros((1, input_sz[0], input_sz[1], input_sz[2], 1), dtype=img.dtype)
                patch_img[0,:,:,:,0] = img[row:row+input_sz[0], col:col+input_sz[1], vol:vol+input_sz[2]]
                patch_predict = unet_model.predict(patch_img)
                predict_img[row+gap[0]:row+gap[0]+step[0], col+gap[1]:col+gap[1]+step[1], vol+gap[2]:vol+gap[2]+step[2]] \
                    = patch_predict[0,:,:,:,0]

    predict_img[predict_img>=0.5] = 255
    predict_img[predict_img<0.5] = 0
    predict_img = np.uint8(predict_img)
    predict_img = predict_img[gap[0]:predict_img.shape[0]-input_sz[0], gap[1]:predict_img.shape[1]-input_sz[1], gap[2]:predict_img.shape[2]-input_sz[2]]

    if mask is not None:
        mask[mask!=0] = 1
        predict_img = predict_img * mask

    K.clear_session()
    gc.collect()
    print("U-Net DONE!")
    print("Non-zero:", np.count_nonzero(predict_img))
    return predict_img


def main():
    parser = argparse.ArgumentParser(description='Apply U-NET')

    parser.add_argument('-i', '--input', dest='input_path', type=str, required=True, \
        help='Path to the input n5')

    parser.add_argument('-d', '--data_set', dest='data_set', type=str, default="/s0", \
        help='Path to data set (default "/s0")')

    parser.add_argument('-o', '--output', dest='output_path', type=str, required=True, \
        help='Path to the (already existing) output n5')

    parser.add_argument('-m', '--model', dest='model_path', type=str, required=True, \
        help='Path to the U-Net model n5')

    parser.add_argument('--start', dest='start_coord', type=str, required=True, metavar='x1,y1,z1', \
        help='Starting coordinate (x,y,z) of block to process')

    parser.add_argument('--end', dest='end_coord', type=str, required=True, metavar='x2,y2,z2', \
        help='Ending coordinate (x,y,z) of block to process')
        
    args = parser.parse_args()
    start = tuple([int(d) for d in args.start_coord.split(',')])
    end = tuple([int(d) for d in args.end_coord.split(',')])

    # Read part of the n5 based upon location
    img = read_n5_block(args.input_path, args.data_set, start, end)

    print('Applying 3D U-Net...')
    start_time = time.time()
    img = apply_unet(img, args.model_path)
    print("DONE!! Running time is {} seconds".format(time.time()-start_time))

    # Write to the same block in the output n5
    write_n5_block(args.output_path, args.data_set, start, end, img)

    print('DONE!')


if __name__ == "__main__":
    main()