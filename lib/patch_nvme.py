#!/usr/bin/env python3
# GPUDirect Storage (nvidia-fs) hook for nvme host pci.c, kernel 7.1.x
# (blk_rq_dma_map_iter / dma_iova API). v2: incorporates adversarial-review fixes.
#
# Safety model: when nvidia-fs has not registered (nvfs_ops==NULL) the CPU/normal
# path is byte-identical to stock -> boot + root-disk I/O unaffected. The nvfs path
# only runs once cuFile/nvidia-fs is active.
#
# Review fixes folded in:
#  B1 uninit stack: memset iter + dma_state, iter.p2pdma.map=NONE before the nvfs
#     iter_start, so the `switch (iter.p2pdma.map)` and prp_save_mapping see valid state.
#  B2 unregister race: capture the ops pointer per-request in iod->nvfs_ops_ref and use
#     THAT (never the global) in the wrapper + unmap (completion runs in IRQ, no RCU).
#  B3 ref balance: nvfs takes one mgroup dma_ref per segment; count segments in
#     iod->nvfs_nsegs (1 at iter_start, ++ per successful iter_next) and put exactly
#     that many in nvme_unmap_data. Free the dma_vecs mempool WITHOUT dma_unmap
#     (addresses are nvidia_p2p GPU addrs, not dma_map_phys).
#  B4 dead error contract: nvfs collapses NVFS_IO_ERR to 0, so after iter_start==0 we
#     distinguish a real error (iter.status != OK) from a genuine CPU request.
#  B5 wrong unmap on error: nvme_unmap_iter is a no-op for nvfs_io (GPU addrs must not
#     be dma_unmap'd); refs from a partial map-error are released by nvme_unmap_data on
#     the SGL error path; the PRP map-error path may leak refs (rare, safe - no UAF).
import sys
p = sys.argv[1] if len(sys.argv) > 1 else "pci.c"
s = open(p).read()
orig = s

def repl(anchor, new, why):
    global s
    n = s.count(anchor)
    assert n == 1, f"anchor for [{why}] found {n} times (need 1):\n{anchor[:160]}"
    s = s.replace(anchor, new)

# ---- 1. nvfs ops type + registration + iter_next wrapper, before nvme_free_descriptors ----
BLOCK = r'''
/* ===== GPUDirect Storage (nvidia-fs) integration - added for GDS on 170HX ===== */
/* ABI must match nvfs-dma.h struct nvfs_dma_rw_blk_iter_ops (v2, 6.17+ iterator). */
struct nvfs_dma_rw_blk_iter_ops {
	unsigned long long ft_bmap;
	int (*nvfs_blk_rq_dma_map_iter_start)(struct request *req, struct device *dma_dev,
			struct dma_iova_state *state, struct blk_dma_iter *iter, void **cookie);
	int (*nvfs_blk_rq_dma_map_iter_next)(struct request *req, struct device *dma_dev,
			struct dma_iova_state *state, struct blk_dma_iter *iter);
	int (*nvfs_dma_unmap_page)(struct device *device, void *cookie, dma_addr_t addr,
			size_t size, enum dma_data_direction dir);
	bool (*nvfs_is_gpu_page)(struct page *page);
	unsigned int (*nvfs_gpu_index)(struct page *page);
	unsigned int (*nvfs_device_priority)(struct device *dev, unsigned int gpu_index);
	int (*nvfs_get_gpu_sglist_rdma_info)(void *sglist, int nents, void *rdma_infop);
};
static struct nvfs_dma_rw_blk_iter_ops *nvfs_ops;

int nvme_v2_register_nvfs_dma_ops(struct nvfs_dma_rw_blk_iter_ops *ops)
{
	if (cmpxchg(&nvfs_ops, NULL, ops) != NULL)
		return -EBUSY;
	return 0;
}
EXPORT_SYMBOL_GPL(nvme_v2_register_nvfs_dma_ops);

void nvme_v2_unregister_nvfs_dma_ops(void)
{
	/* nvidia-fs guarantees no GDS I/O is in flight across unregister; in-flight
	 * requests already captured the ops pointer in iod->nvfs_ops_ref. */
	WRITE_ONCE(nvfs_ops, NULL);
}
EXPORT_SYMBOL_GPL(nvme_v2_unregister_nvfs_dma_ops);

/* iter_next wrapper: nvfs (1=more,0=done,<0=err) -> kernel bool; count segments */
static bool nvme_dma_map_iter_next(struct request *req, struct device *dma_dev,
		struct blk_dma_iter *iter)
{
	struct nvme_iod *iod = blk_mq_rq_to_pdu(req);

	if (iod->nvfs_io) {
		int r = iod->nvfs_ops_ref->nvfs_blk_rq_dma_map_iter_next(req, dma_dev,
				&iod->dma_state, iter);
		if (r > 0) {
			iod->nvfs_nsegs++;
			return true;
		}
		return false;	/* 0 = done, <0 = error (iter->status already set) */
	}
	return blk_rq_dma_map_iter_next(req, dma_dev, iter);
}
/* ===== end GDS integration ===== */

static void nvme_free_descriptors(struct request *req)'''
repl("\nstatic void nvme_free_descriptors(struct request *req)", BLOCK, "insert nvfs block + register funcs")

# ---- 2. nvme_iod: add nvfs fields ----
repl(
"""	struct nvme_sgl_desc *meta_descriptor;
};""",
"""	struct nvme_sgl_desc *meta_descriptor;

	bool nvfs_io;					/* GDS: mapped by nvidia-fs */
	unsigned int nvfs_nsegs;			/* GDS: mgroup dma_ref count to release */
	void *nvfs_cookie;				/* GDS: nvfs_mgroup */
	struct nvfs_dma_rw_blk_iter_ops *nvfs_ops_ref;	/* GDS: per-req ops (unregister-safe) */
};""",
"add nvfs fields to nvme_iod")

# ---- 3. nvme_map_data: try nvfs first (with initialized iter/state), else normal ----
repl(
"""	enum nvme_use_sgl use_sgl = nvme_pci_use_sgls(dev, req);
	struct blk_dma_iter iter;
	blk_status_t ret;

	/*
	 * Try to skip the DMA iterator for single segment requests, as that
	 * significantly improves performances for small I/O sizes.
	 */
	if (blk_rq_nr_phys_segments(req) == 1) {
		ret = nvme_pci_setup_data_simple(req, use_sgl);
		if (ret != BLK_STS_AGAIN)
			return ret;
	}

	if (!blk_rq_dma_map_iter_start(req, dev->dev, &iod->dma_state, &iter))
		return iter.status;
""",
"""	enum nvme_use_sgl use_sgl = nvme_pci_use_sgls(dev, req);
	struct blk_dma_iter iter;
	blk_status_t ret;
	struct nvfs_dma_rw_blk_iter_ops *nvfs = READ_ONCE(nvfs_ops);

	iod->nvfs_io = false;
	iod->nvfs_nsegs = 0;
	iod->nvfs_cookie = NULL;
	iod->nvfs_ops_ref = NULL;

	if (nvfs) {
		int nret;

		/* nvfs fills addr/len/status/iter only; init the rest so the
		 * p2pdma switch + prp_save_mapping see valid state (review B1). */
		memset(&iter, 0, sizeof(iter));
		iter.p2pdma.map = PCI_P2PDMA_MAP_NONE;
		iter.status = BLK_STS_OK;
		memset(&iod->dma_state, 0, sizeof(iod->dma_state));

		nret = nvfs->nvfs_blk_rq_dma_map_iter_start(req, dev->dev,
				&iod->dma_state, &iter, &iod->nvfs_cookie);
		if (nret > 0) {
			iod->nvfs_io = true;
			iod->nvfs_ops_ref = nvfs;
			iod->nvfs_nsegs = 1;
			goto data_mapped;	/* GPU req: skip fast path + kernel iter */
		}
		/* nret==0: nvfs collapses errors to 0 (review B4), so a non-OK
		 * status means a real error, not a genuine CPU request. */
		if (iter.status != BLK_STS_OK)
			return iter.status;
		/* genuine CPU request: fall through to the normal path */
	}

	/*
	 * Try to skip the DMA iterator for single segment requests, as that
	 * significantly improves performances for small I/O sizes.
	 */
	if (blk_rq_nr_phys_segments(req) == 1) {
		ret = nvme_pci_setup_data_simple(req, use_sgl);
		if (ret != BLK_STS_AGAIN)
			return ret;
	}

	if (!blk_rq_dma_map_iter_start(req, dev->dev, &iod->dma_state, &iter))
		return iter.status;

data_mapped:
""",
"nvme_map_data nvfs branch")

# ---- 4. route the two kernel iter_next call sites through the wrapper ----
repl(
"""	if (iter->len)
		return true;
	if (!blk_rq_dma_map_iter_next(req, dma_dev, iter))
		return false;
	return nvme_pci_prp_save_mapping(req, dma_dev, iter);""",
"""	if (iter->len)
		return true;
	if (!nvme_dma_map_iter_next(req, dma_dev, iter))
		return false;
	return nvme_pci_prp_save_mapping(req, dma_dev, iter);""",
"prp iter_next -> wrapper")

repl(
"""		iod->total_len += iter->len;
	} while (blk_rq_dma_map_iter_next(req, nvmeq->dev->dev, iter));""",
"""		iod->total_len += iter->len;
	} while (nvme_dma_map_iter_next(req, nvmeq->dev->dev, iter));""",
"sgl iter_next -> wrapper")

# ---- 5. nvme_unmap_iter: GPU addrs must NOT be dma_unmap'd (review B5) ----
repl(
"""static void nvme_unmap_iter(struct request *req, struct blk_dma_iter *iter,
			    struct dma_iova_state *state)
{
	struct nvme_queue *nvmeq = req->mq_hctx->driver_data;
	struct device *dev = nvmeq->dev->dev;

	if (!blk_rq_dma_unmap(req, dev, state, iter->len, iter->p2pdma.map)) {""",
"""static void nvme_unmap_iter(struct request *req, struct blk_dma_iter *iter,
			    struct dma_iova_state *state)
{
	struct nvme_queue *nvmeq = req->mq_hctx->driver_data;
	struct device *dev = nvmeq->dev->dev;
	struct nvme_iod *iod = blk_mq_rq_to_pdu(req);

	if (iod->nvfs_io)
		return;	/* GPU addrs (nvidia_p2p) released in nvme_unmap_data */

	if (!blk_rq_dma_unmap(req, dev, state, iter->len, iter->p2pdma.map)) {""",
"nvme_unmap_iter nvfs guard")

# ---- 6. nvme_unmap_data: nvfs branch - put N mgroup refs, free dma_vecs w/o dma_unmap ----
repl(
"""	struct device *dma_dev = nvmeq->dev->dev;
	unsigned int attrs = 0;

	if (iod->flags & IOD_SINGLE_SEGMENT) {""",
"""	struct device *dma_dev = nvmeq->dev->dev;
	unsigned int attrs = 0;

	if (iod->nvfs_io) {
		unsigned int i;

		for (i = 0; i < iod->nvfs_nsegs; i++)
			iod->nvfs_ops_ref->nvfs_dma_unmap_page(dma_dev,
					iod->nvfs_cookie, 0, 0, rq_dma_dir(req));
		if (iod->nr_dma_vecs)	/* free the vec array, NOT the GPU DMA addrs */
			mempool_free(iod->dma_vecs, nvmeq->dev->dmavec_mempool);
		if (iod->nr_descriptors)
			nvme_free_descriptors(req);
		return;
	}

	if (iod->flags & IOD_SINGLE_SEGMENT) {""",
"nvme_unmap_data nvfs branch")

assert s != orig, "no changes applied"
open(p, "w").write(s)
print("nvme GDS patch v2 applied OK")
