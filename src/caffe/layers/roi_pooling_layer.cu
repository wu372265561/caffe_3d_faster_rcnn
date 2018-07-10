// ------------------------------------------------------------------
// Fast R-CNN
// Copyright (c) 2015 Microsoft
// Licensed under The MIT License [see fast-rcnn/LICENSE for details]
// Written by Ross Girshick
// ------------------------------------------------------------------

#include <cfloat>

#include "caffe/fast_rcnn_layers.hpp"

using std::max;
using std::min;

namespace caffe {

template <typename Dtype>
__global__ void ROIPoolForward(const int nthreads, const Dtype* bottom_data,
	const Dtype spatial_scale_xy, const Dtype spatial_scale_z, const int channels,
    const int length, const int height, const int width, 
    const int pooled_length, const int pooled_height, const int pooled_width,
    const Dtype* bottom_rois, Dtype* top_data, int* argmax_data) {
	CUDA_KERNEL_LOOP(index, nthreads) {

		// (n, c, pl, ph, pw) is an element in the pooled output
		int pw = index % pooled_width;
		int ph = (index / pooled_width) % pooled_height;
		int pl = (index / pooled_width / pooled_height) % pooled_length;
		int c = (index / pooled_width / pooled_height / pooled_length) % channels;
		int n = index / pooled_width / pooled_height / pooled_length / channels;

		int roi_offset = n * 7;
		int roi_batch_ind = bottom_rois[roi_offset + 0];
		int roi_start_w = round(bottom_rois[roi_offset + 1] * spatial_scale_xy);
		int roi_start_h = round(bottom_rois[roi_offset + 2] * spatial_scale_xy);
		int roi_start_l = round(bottom_rois[roi_offset + 3] * spatial_scale_z);
		int roi_end_w = round(bottom_rois[roi_offset + 4] * spatial_scale_xy);
		int roi_end_h = round(bottom_rois[roi_offset + 5] * spatial_scale_xy);
		int roi_end_l = round(bottom_rois[roi_offset + 6] * spatial_scale_z);

		// Force malformed ROIs to be 1x1
		int roi_width = max(roi_end_w - roi_start_w + 1, 1);
		int roi_height = max(roi_end_h - roi_start_h + 1, 1);
		int roi_length = max(roi_end_l - roi_start_l + 1, 1);
		Dtype bin_size_l = static_cast<Dtype>(roi_length) / static_cast<Dtype>(pooled_length);
		Dtype bin_size_h = static_cast<Dtype>(roi_height) / static_cast<Dtype>(pooled_height);
		Dtype bin_size_w = static_cast<Dtype>(roi_width) / static_cast<Dtype>(pooled_width);

		int lstart = static_cast<int>(floor(static_cast<Dtype>(pl) * bin_size_l));
		int hstart = static_cast<int>(floor(static_cast<Dtype>(ph) * bin_size_h));
		int wstart = static_cast<int>(floor(static_cast<Dtype>(pw) * bin_size_w));
		int lend = static_cast<int>(ceil(static_cast<Dtype>(pl + 1) * bin_size_l));
		int hend = static_cast<int>(ceil(static_cast<Dtype>(ph + 1) * bin_size_h));
		int wend = static_cast<int>(ceil(static_cast<Dtype>(pw + 1) * bin_size_w));

		// Add roi offsets and clip to input boundaries
		lstart = min(max(lstart + roi_start_l, 0), length);
		lend = min(max(lend + roi_start_l, 0), length);
		hstart = min(max(hstart + roi_start_h, 0), height);
		hend = min(max(hend + roi_start_h, 0), height);
		wstart = min(max(wstart + roi_start_w, 0), width);
		wend = min(max(wend + roi_start_w, 0), width);
		bool is_empty = (lend <= lstart) || (hend <= hstart) || (wend <= wstart);

		// Define an empty pooling region to be zero
		Dtype maxval = is_empty ? 0 : -FLT_MAX;
		// If nothing is pooled, argmax = -1 causes nothing to be backprop'd
		int maxidx = -1;
		int data_offset = (roi_batch_ind * channels + c) * length * height * width;
		for (int l = lstart; l < lend; ++l) {
			for (int h = hstart; h < hend; ++h) {
			for (int w = wstart; w < wend; ++w) {
				int bottom_index = l * height * width + h * width + w;
				if (bottom_data[data_offset + bottom_index] > maxval) {
					maxval = bottom_data[data_offset + bottom_index];
					maxidx = bottom_index;
				}
			}
			}
		}
		top_data[index] = maxval;
		argmax_data[index] = maxidx;
	}
}

template <typename Dtype>
void ROIPoolingLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {

	const Dtype* bottom_data = bottom[0]->gpu_data();
	const Dtype* bottom_rois = bottom[1]->gpu_data();
	Dtype* top_data = top[0]->mutable_gpu_data();
	int* argmax_data = max_idx_.mutable_gpu_data();
	int count = top[0]->count();

	// NOLINT_NEXT_LINE(whitespace/operators)
	ROIPoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
		count, bottom_data, spatial_scale_xy_, spatial_scale_z_, channels_, length_, height_, width_,
		pooled_length_, pooled_height_, pooled_width_, bottom_rois, top_data, argmax_data);

	CUDA_POST_KERNEL_CHECK;
}

template <typename Dtype>
__global__ void ROIPoolBackward(const int nthreads, const Dtype* top_diff,
	const int* argmax_data, const int num_rois, const Dtype spatial_scale_xy, const Dtype spatial_scale_z,
    const int channels, const int length, const int height, const int width,
    const int pooled_length, const int pooled_height, const int pooled_width, 
    Dtype* bottom_diff, const Dtype* bottom_rois) {

CUDA_KERNEL_LOOP(index, nthreads) {
		// (n, c, l, h, w) coords in bottom data
		int w = index % width;
		int h = (index / width) % height;
		int l = (index / width / height) % length;
		int c = (index / width / height / length) % channels;
		int n = index / width / height / length / channels;

		Dtype gradient = 0;
		// Accumulate gradient over all ROIs that pooled this element
		for (int roi_n = 0; roi_n < num_rois; ++roi_n) {
			const Dtype* offset_bottom_rois = bottom_rois + roi_n * 7;
			int roi_batch_ind = offset_bottom_rois[0];
			// Skip if ROI's batch index doesn't match n
			if (n != roi_batch_ind) {
				continue;
			}

			int roi_start_w = round(offset_bottom_rois[1] * spatial_scale_xy);
			int roi_start_h = round(offset_bottom_rois[2] * spatial_scale_xy);
			int roi_start_l = round(offset_bottom_rois[3] * spatial_scale_z);
			int roi_end_w = round(offset_bottom_rois[4] * spatial_scale_xy);
			int roi_end_h = round(offset_bottom_rois[5] * spatial_scale_xy);
			int roi_end_l = round(offset_bottom_rois[6] * spatial_scale_z);

			// Skip if ROI doesn't include (h, w)
			const bool in_roi = (w >= roi_start_w && w <= roi_end_w &&
								h >= roi_start_h && h <= roi_end_h &&
								l >= roi_start_l && l <= roi_end_l);
			if (!in_roi) {
				continue;
			}

			int offset = (roi_n * channels + c) * pooled_length * pooled_height * pooled_width;
			const Dtype* offset_top_diff = top_diff + offset;
			const int* offset_argmax_data = argmax_data + offset;

			// Compute feasible set of pooled units that could have pooled
			// this bottom unit

			// Force malformed ROIs to be 1x1
			int roi_width = max(roi_end_w - roi_start_w + 1, 1);
			int roi_height = max(roi_end_h - roi_start_h + 1, 1);
			int roi_length = max(roi_end_l - roi_start_l + 1, 1);

			Dtype bin_size_l = static_cast<Dtype>(roi_length) / static_cast<Dtype>(pooled_length);
			Dtype bin_size_h = static_cast<Dtype>(roi_height) / static_cast<Dtype>(pooled_height);
			Dtype bin_size_w = static_cast<Dtype>(roi_width) / static_cast<Dtype>(pooled_width);

			int plstart = floor(static_cast<Dtype>(l - roi_start_l) / bin_size_l);
			int plend = ceil(static_cast<Dtype>(l - roi_start_l + 1) / bin_size_l);
			int phstart = floor(static_cast<Dtype>(h - roi_start_h) / bin_size_h);
			int phend = ceil(static_cast<Dtype>(h - roi_start_h + 1) / bin_size_h);
			int pwstart = floor(static_cast<Dtype>(w - roi_start_w) / bin_size_w);
			int pwend = ceil(static_cast<Dtype>(w - roi_start_w + 1) / bin_size_w);

			plstart = min(max(plstart, 0), pooled_length);
			plend = min(max(plend, 0), pooled_length);
			phstart = min(max(phstart, 0), pooled_height);
			phend = min(max(phend, 0), pooled_height);
			pwstart = min(max(pwstart, 0), pooled_width);
			pwend = min(max(pwend, 0), pooled_width);

			for (int pl = plstart; pl < plend; ++pl) {
				for (int ph = phstart; ph < phend; ++ph) {
					for (int pw = pwstart; pw < pwend; ++pw) {
						if (offset_argmax_data[pl * pooled_height * pooled_width + ph * pooled_width + pw] == (l * height * width + h * width + w)) {
							gradient += offset_top_diff[pl * pooled_height * pooled_width + ph * pooled_width + pw];
						}
					}
				}
			}
		}
		bottom_diff[index] = gradient;
	}
}

template <typename Dtype>
void ROIPoolingLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {
  if (!propagate_down[0]) {
    return;
  }
  const Dtype* bottom_rois = bottom[1]->gpu_data();
  const Dtype* top_diff = top[0]->gpu_diff();
  Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();
  const int count = bottom[0]->count();
  caffe_gpu_set(count, Dtype(0.), bottom_diff);
  const int* argmax_data = max_idx_.gpu_data();
  // NOLINT_NEXT_LINE(whitespace/operators)
  ROIPoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
	  count, top_diff, argmax_data, top[0]->num(), spatial_scale_xy_, spatial_scale_z_, channels_,
      length_, height_, width_, pooled_length_, pooled_height_, pooled_width_, bottom_diff, bottom_rois);
  CUDA_POST_KERNEL_CHECK;
}

INSTANTIATE_LAYER_GPU_FUNCS(ROIPoolingLayer);

}  // namespace caffe
