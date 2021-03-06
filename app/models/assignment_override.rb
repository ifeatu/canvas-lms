#
# Copyright (C) 2012 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class AssignmentOverride < ActiveRecord::Base
  include Workflow
  include TextHelper

  simply_versioned :keep => 5

  attr_accessible

  belongs_to :assignment
  belongs_to :set, :polymorphic => true
  has_many :assignment_override_students, :dependent => :destroy

  validates_presence_of :assignment, :assignment_version, :title
  validates_inclusion_of :set_type, :in => %w(CourseSection Group ADHOC)
  validates_length_of :title, :maximum => maximum_string_length, :allow_nil => true

  concrete_set = lambda{ |override| ['CourseSection', 'Group'].include?(override.set_type) }

  validates_presence_of :set, :set_id, :if => concrete_set
  validates_uniqueness_of :set_id, :scope => [:assignment_id, :set_type, :workflow_state], :if => lambda{ |override| override.active? && concrete_set.call(override) }
  validate :if => concrete_set do |record|
    if record.set && record.assignment
      case record.set
      when CourseSection
        record.errors.add :set, "not from assignment's course" unless record.set.course_id == record.assignment.context_id
      when Group
        record.errors.add :set, "not from assignment's group category" unless record.deleted? || record.set.group_category_id == record.assignment.group_category_id
      end
    end
  end

  validate :set_id, :unless => concrete_set do |record|
    if record.set_type == 'ADHOC' && !record.set_id.nil?
      record.errors.add :set_id, "must be nil with set_type ADHOC"
    end
  end

  workflow do
    state :active
    state :deleted
  end

  alias_method :destroy!, :destroy
  def destroy
    transaction do
      self.assignment_override_students.destroy_all
      self.workflow_state = 'deleted'
      self.save!
    end
  end

  named_scope :active, :conditions => { :workflow_state => 'active' }

  before_validation :default_values
  def default_values
    self.set_type ||= 'ADHOC'
    self.assignment_version = assignment.version_number if assignment
    self.title = set.name if set_type != 'ADHOC' && set
  end
  protected :default_values

  # override set read accessor and set_id read/write accessors so that reading
  # set/set_id or setting set_id while set_type=ADHOC doesn't try and find the
  # ADHOC model
  def set_id
    read_attribute(:set_id)
  end

  def set_with_adhoc
    if self.set_type == 'ADHOC'
      assignment_override_students.scoped(:include => :user).map(&:user)
    else
      set_without_adhoc
    end
  end
  alias_method_chain :set, :adhoc

  def set_id=(id)
    if self.set_type == 'ADHOC'
      write_attribute(:set_id, id)
    else
      super
    end
  end

  def self.override(field)
    define_method "override_#{field}" do |value|
      send("#{field}_overridden=", true)
      send("#{field}=", value)
    end

    define_method "clear_#{field}_override" do
      send("#{field}_overridden=", false)
      send("#{field}=", nil)
    end

    validates_inclusion_of "#{field}_overridden", :in => [false, true]
    before_validation do |override|
      if override.send("#{field}_overridden").nil?
        override.send("#{field}_overridden=", false)
      end
      true
    end

    named_scope "overriding_#{field}", :conditions => { "#{field}_overridden" => true }
  end

  override :due_at
  override :unlock_at
  override :lock_at

  def due_at=(new_due_at)
    new_all_day, new_all_day_date = Assignment.all_day_interpretation(
      :due_at => new_due_at,
      :due_at_was => read_attribute(:due_at),
      :all_day_was => read_attribute(:all_day),
      :all_day_date_was => read_attribute(:all_day_date))

    write_attribute(:due_at, new_due_at)
    write_attribute(:all_day, new_all_day)
    write_attribute(:all_day_date, new_all_day_date)
  end

  def as_hash
    { :title => title,
      :due_at => due_at,
      :all_day => all_day,
      :all_day_date => all_day_date,
      :override => self }
  end

  named_scope :visible_to, lambda{ |admin, course|
    scopes = []

    # adhoc overrides for visible students
    scopes << course.enrollments_visible_to(admin).scoped(
      :select => "DISTINCT assignment_override_students.assignment_override_id AS id",
      :joins => "INNER JOIN assignment_override_students ON assignment_override_students.user_id=enrollments.user_id"
    )

    # group overrides for visible groups
    scopes << course.groups_visible_to(admin).scoped(
      :select => "assignment_overrides.id",
      :joins => "INNER JOIN assignment_overrides ON assignment_overrides.set_type='Group' AND groups.id=assignment_overrides.set_id"
    )

    # section overrides for visible sections
    scopes << course.sections_visible_to(admin).scoped(
      :select => "assignment_overrides.id",
      :joins => "INNER JOIN assignment_overrides ON assignment_overrides.set_type='CourseSection' AND course_sections.id=assignment_overrides.set_id"
    )

    # union the visible override subselects and join against them
    subselect = scopes.map{ |scope| scope.construct_finder_sql({}) }.join(' UNION ')
    { :joins => "INNER JOIN (#{subselect}) AS visible_overrides ON visible_overrides.id=assignment_overrides.id" }
  }
end
