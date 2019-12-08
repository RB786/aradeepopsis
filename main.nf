#!/usr/bin/env nextflow

/*
========================================================================================
                            a r a D e e p o p s i s
========================================================================================
 Nextflow pipeline to run semantic segmentation on plant rosette images with deepLab V3+
 #### Author
 Patrick Hüther <patrick.huether@gmi.oeaw.ac.at>
----------------------------------------------------------------------------------------
*/

Channel
    .fromPath(params.images, checkIfExists: true)
    .into { ch_images; ch_dimensions }

process get_dimensions {
    input:
        file(images) from ch_dimensions.collect() 
    output:
        stdout ch_maxdimensions
    script:
"""
#!/usr/bin/env python

import glob
import imagesize

print(max(imagesize.get(img) for img in glob.glob('*')))
"""
}

process build_records {
    publishDir "${params.outdir}/shards", mode: 'copy'
    input:
        file('images/*') from ch_images.buffer(size:params.chunksize, remainder: true)
    output:
        file('*.tfrecord') into ch_shards
        file('*txt') into invalid_images optional true
    script:
"""
#!/usr/bin/env python

import logging
import os

import tensorflow as tf

from data_record import create_record

logger = tf.get_logger()
logger.setLevel('INFO')

images = tf.io.gfile.glob('images/*')

count = len(images)
invalid = 0

with tf.io.TFRecordWriter('chunk.tfrecord') as writer:
  for i in range(count):
    filename = os.path.basename(images[i])
    image_data = tf.io.gfile.GFile(images[i], 'rb').read()
    try:
      image = tf.io.decode_image(image_data, channels=3, expand_animations=False)
    except tf.errors.InvalidArgumentError:
      logger.info("%s is either corrupted or not a supported image format" % filename)
      invalid += 1
      with open("invalid.txt", "a") as broken:
        broken.write(f'{filename}\\n')
      continue

    height, width = image.shape[:2]

    record = create_record(image_data, filename, height, width, 3)
    writer.write(record.SerializeToString())

logger.info("Converted %d images to tfrecords, found %d invalid images" % (count - invalid, invalid))
assert invalid != count, "Could not convert any images, make sure to use only valid png or jpeg images!"
"""
}

invalid_images
 .collectFile(name: 'invalid_images.txt', storeDir: params.outdir)

process run_predictions {
    publishDir "${params.outdir}/predictions", mode: 'copy',
        saveAs: { filename ->
                    if (filename.startsWith("mask_")) "mask/$filename"
                    else if (filename.startsWith("convex_hull_")) "convex_hull/$filename"
                    else null
                }
    input:
        file(shard) from ch_shards
        val(dim) from ch_maxdimensions
    output:
        file('*.csv') into results
        file('*.png') into predictions

    script:
def scale = params.multiscale ? 'multi' : 'single'
def mask = params.save_mask ? 'True' : 'False'
def hull = params.save_hull ? 'True' : 'False'
"""
#!/usr/bin/env python

import logging
import numpy as np
import time

import tensorflow as tf

from data_record import parse_record
from frozen_graph import wrap_frozen_graph
from traits import measure_traits

logger = tf.get_logger()
logger.setLevel('INFO')

with tf.io.gfile.GFile('${baseDir}/model/frozengraph/${scale}.pb', "rb") as f:
    graph_def = tf.compat.v1.GraphDef()
    graph_def.ParseFromString(f.read())

predict = wrap_frozen_graph(
    graph_def,
    inputs='ImageTensor:0',
    outputs='SemanticPredictions:0')

dataset = (
    tf.data.TFRecordDataset('${shard}')
    .map(parse_record)
    .batch(1)
    .prefetch(1)
    .enumerate(start=1))

size = len(list(dataset))

for index, sample in dataset:
        filename = sample['filename'].numpy()[0].decode('utf-8')
        logger.info("Running prediction on image %s (%d/%d)" % (filename,index,size))
        original_image =  sample['image'].numpy()
        segmentation = predict(sample['image'])
        measure_traits(np.squeeze(segmentation),
                                   np.squeeze(original_image),
                                   filename,
                                   save_mask=True,
                                   save_hull=False,
                                   get_regionprops=True,
                                   label_names=['background', 'rosette'],
                                   channelstats=True)
"""
}
 
results
 .collectFile(name: 'aradeepopsis_traits.csv', storeDir: params.outdir)
