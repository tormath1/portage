# Copyright 1999-2011 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

import time

from _emerge.PollScheduler import PollScheduler

class QueueScheduler(PollScheduler):

	"""
	Add instances of SequentialTaskQueue and then call run(). The
	run() method returns when no tasks remain.
	"""

	def __init__(self, max_jobs=None, max_load=None):
		PollScheduler.__init__(self)

		if max_jobs is None:
			max_jobs = 1

		self._max_jobs = max_jobs
		self._max_load = max_load

		self._queues = []
		self._schedule_listeners = []

	def add(self, q):
		self._queues.append(q)

	def remove(self, q):
		self._queues.remove(q)

	def clear(self):
		for q in self._queues:
			q.clear()

	def run(self, timeout=None):

		timeout_id = None
		if timeout is not None:
			def timeout_callback():
				raise StopIteration()
			timeout_id = self._timeout_add(timeout, timeout_callback)

		try:

			while self._schedule():
				self._iteration()

			while self._running_job_count():
				self._iteration()

		except StopIteration:
			pass

		if timeout_id is not None:
			self._unregister(timeout_id)

	def _schedule_tasks(self):
		"""
		@rtype: bool
		@returns: True if there may be remaining tasks to schedule,
			False otherwise.
		"""
		if self._terminated_tasks:
			return False

		while self._can_add_job():
			n = self._max_jobs - self._running_job_count()
			if n < 1:
				break

			if not self._start_next_job(n):
				return False

		for q in self._queues:
			if q:
				return True
		return False

	def _running_job_count(self):
		job_count = 0
		for q in self._queues:
			job_count += len(q.running_tasks)
		self._jobs = job_count
		return job_count

	def _start_next_job(self, n=1):
		started_count = 0
		for q in self._queues:
			initial_job_count = len(q.running_tasks)
			q.schedule()
			final_job_count = len(q.running_tasks)
			if final_job_count > initial_job_count:
				started_count += (final_job_count - initial_job_count)
			if started_count >= n:
				break
		return started_count

